import Foundation
import os

private let editServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceEditService"
)

private struct WorkplaceEditBranchRollback {
    let path: String
    let branch: String
}

/// 编辑工作区过程中的本地目录还原失败。
/// 携带暂存路径,便于在 UI 上告知用户去哪里取回未还原的仓库目录。
enum WorkplaceEditServiceError: LocalizedError {
    case stagedItemRestoreFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .stagedItemRestoreFailed(path, reason):
            return "还原仓库目录失败（\(reason)）。文件仍保留在暂存目录中，可手动取回：\(path)"
        }
    }
}

@MainActor
struct WorkplaceEditService {
    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    let syncCoordinator: SyncCoordinator
    let gitService: GitServicing

    func saveWorkplaceEdit(
        workplaceID: UUID,
        name: String,
        selectedRepositoryIDs: [UUID],
        branch: String?,
        progressHandler: WorkplaceOperationProgressHandler? = nil
    ) async throws {
        guard let originalWorkplace = workplaceStore.workplaces.first(where: { $0.id == workplaceID }) else { return }
        guard selectedRepositoryIDs.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }
        let validatedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBranch = normalizedBranch?.isEmpty == true ? nil : normalizedBranch

        let currentSelectedIDs = Set(originalWorkplace.selectedRepositoryIDs)
        let nextSelectedIDs = Set(selectedRepositoryIDs)
        let removedRepositoryIDs = currentSelectedIDs.subtracting(nextSelectedIDs)
        let addedRepositoryIDs = nextSelectedIDs.subtracting(currentSelectedIDs)
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplaceID }
        // 与其他处一致:循环构建字典,重复 id 时后者覆盖前者而非 trap。
        var repositoryNamesByID = Dictionary<UUID, String>(minimumCapacity: repositoryStore.repositories.count)
        for repository in repositoryStore.repositories {
            repositoryNamesByID[repository.id] = repository.repoName
        }
        let oldPath = originalWorkplace.path
        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let newPath = try WorkplaceStore.workplacePath(
            rootPath: parentPath,
            name: validatedName
        )

        let normalizedNewPath = URL(fileURLWithPath: newPath).standardizedFileURL.path
        guard !workplaceStore.workplaces.contains(where: {
            $0.id != workplaceID &&
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedNewPath
        }) else {
            throw WorkplaceStoreError.duplicatePath
        }
        guard normalizedNewPath == WorkplaceStore.normalizedPath(oldPath) ||
                FileManager.default.fileExists(atPath: newPath) == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }
        try ensureManagedSyncStates(originalStates, within: oldPath)

        let renamed = newPath != oldPath
        let removalStagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-space-edit-\(UUID().uuidString)", isDirectory: true)
        var stagedRemovals: [(originalPath: String, stagedPath: String)] = []
        var clonedStates: [RepositorySyncState] = []
        var branchRollbacks: [WorkplaceEditBranchRollback] = []

        do {
            if renamed {
                // 目录移动同样要与仓库级写操作互斥:锁 key 精确匹配,须把
                // 旧/新目录本身与两侧全部仓库路径一起罩住。跨卷移动会退化为
                // "复制整树+删除原树",与并发 git 写入交错会拷出不一致的仓库副本。
                var renameLockPaths = [oldPath, newPath]
                renameLockPaths.append(contentsOf: originalStates.map(\.localPath))
                renameLockPaths.append(
                    contentsOf: try originalStates.map { state in
                        try updatedSyncStatePath(
                            state,
                            oldWorkplacePath: oldPath,
                            newWorkplacePath: newPath
                        ).localPath
                    }
                )
                // 整棵工作区目录的移动在跨卷时会退化为"复制+删除",可能耗时很久,
                // 移出主线程执行,避免冻结 UI。
                try await RepositoryOperationLock.shared.withLockPaths(renameLockPaths) {
                    try await Self.moveItemOffMainThread(fromPath: oldPath, toPath: newPath)
                }
            }

            var updatedWorkplace = originalWorkplace
            updatedWorkplace.name = validatedName
            updatedWorkplace.path = newPath
            updatedWorkplace.selectedRepositoryIDs = selectedRepositoryIDs
            updatedWorkplace.branch = nextBranch
            updatedWorkplace.updatedAt = .now

            let updatedStates = try originalStates.map { state in
                try updatedSyncStatePath(
                    state,
                    oldWorkplacePath: oldPath,
                    newWorkplacePath: newPath
                )
            }
            let removedStates = updatedStates.filter { removedRepositoryIDs.contains($0.repositoryID) }
            var retainedStates = updatedStates.filter { nextSelectedIDs.contains($0.repositoryID) }
            let removalProgressTracker =
                removedStates.isEmpty
                ? nil
                : WorkplaceOperationProgressTracker(
                    step: .removingRepositories,
                    totalCount: removedStates.count,
                    progressHandler: progressHandler
                )

            for state in removedStates {
                let repositoryName = repositoryDisplayName(
                    for: state,
                    repositoryNamesByID: repositoryNamesByID
                )
                let stagedPath = try await performProgressTrackedOperation(
                    with: removalProgressTracker,
                    repositoryName: repositoryName
                ) {
                    // 移出暂存(跨卷时为复制+删除)与 pull/push 对同一目录的写互斥。
                    try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                        try await stageLocalItemForRemovalIfExists(
                            at: state.localPath,
                            stagingRoot: removalStagingRoot.path
                        )
                    }
                }
                if let stagedPath {
                    stagedRemovals.append((originalPath: state.localPath, stagedPath: stagedPath))
                }
            }

            if nextBranch != originalWorkplace.branch, let branchToCheckout = nextBranch, !branchToCheckout.isEmpty {
                let retainedStatesToSwitch = retainedStates.filter { state in
                    !addedRepositoryIDs.contains(state.repositoryID) && state.hasLocalDirectory
                }
                let branchProgressTracker =
                    retainedStatesToSwitch.isEmpty
                    ? nil
                    : WorkplaceOperationProgressTracker(
                        step: .switchingBranches(branch: branchToCheckout),
                        totalCount: retainedStatesToSwitch.count,
                        progressHandler: progressHandler
                    )

                for index in retainedStates.indices where !addedRepositoryIDs.contains(retainedStates[index].repositoryID) {
                    let state = retainedStates[index]
                    guard state.hasLocalDirectory else {
                        continue
                    }
                    let repositoryName = repositoryDisplayName(
                        for: state,
                        repositoryNamesByID: repositoryNamesByID
                    )
                    do {
                        try await performProgressTrackedOperation(
                            with: branchProgressTracker,
                            repositoryName: repositoryName
                        ) {
                            // 与后台定时 pull/push 互斥,避免对同一工作树交错执行写操作。
                            // 闭包内只做 git 操作,切出的原分支带出来再记录,避免捕获 MainActor 状态。
                            let previousBranch: String? = try await RepositoryOperationLock.shared
                                .withLock(path: state.localPath) { () async throws -> String? in
                                    let currentBranch = await gitService.currentBranch(in: state.localPath)
                                    if currentBranch == branchToCheckout {
                                        return nil
                                    }
                                    try await GitWorktreeSafety.validateCleanWorkingTree(
                                        in: state.localPath,
                                        gitService: gitService,
                                        blockedOperation: .switchBranch
                                    )
                                    try await gitService.checkoutBranch(branchToCheckout, in: state.localPath)
                                    guard let currentBranch, currentBranch.isEmpty == false else { return nil }
                                    return currentBranch
                                }
                            if let previousBranch {
                                branchRollbacks.append(
                                    WorkplaceEditBranchRollback(
                                        path: state.localPath,
                                        branch: previousBranch
                                    )
                                )
                            }
                        }
                        retainedStates[index].lastError = nil
                        retainedStates[index].status = .success
                    } catch {
                        retainedStates[index].lastError = error.localizedDescription
                        retainedStates[index].status = .failed
                    }
                }
            }

            if addedRepositoryIDs.isEmpty == false {
                let addedRepositories = repositoryStore.repositories.filter { addedRepositoryIDs.contains($0.id) }
                if addedRepositories.isEmpty == false {
                    // 与后台定时 pull/push 互斥,避免克隆过程中对同一目录交错执行写操作。
                    // 锁 key 是精确匹配,只锁工作区根路径罩不住仓库级写操作,
                    // 必须把目录自身与每条待克隆的仓库目标路径一起加锁。
                    // 闭包内只捕获 Sendable 的值(不可变副本),避免捕获 MainActor 隔离状态。
                    let workplaceForClone = updatedWorkplace
                    var cloneLockPaths = [newPath]
                    for repository in addedRepositories {
                        cloneLockPaths.append(
                            try WorkplaceStore.repositoryPath(
                                workplacePath: newPath,
                                repositoryName: repository.repoName
                            )
                        )
                    }
                    clonedStates = try await RepositoryOperationLock.shared.withLockPaths(cloneLockPaths) {
                        try await syncCoordinator.cloneRepositories(
                            repositories: addedRepositories,
                            workplace: workplaceForClone,
                            progressHandler: progressHandler
                        )
                    }
                    retainedStates.append(contentsOf: clonedStates)
                }
            }

            try workplaceStore.applyWorkplaceEdit(updatedWorkplace, syncStates: retainedStates)
            // 暂存根目录里可能装着多棵被移出的仓库树,递归删除移出主线程。
            await Self.removeItemOffMainThread(
                syncCoordinator.fileSystemService,
                at: removalStagingRoot.path
            )
        } catch {
            do {
                // 回滚删除的是整棵已克隆仓库目录,递归删除可能耗时很久,移出主线程。
                try await removeClonedItemsIfNeeded(clonedStates)
            } catch {
                editServiceLog.error("event=rollback_cleanup_failed reason=\(error.localizedDescription)")
            }
            // 暂存根目录里可能装着多棵被移出的仓库树,只有全部还原成功才允许清理;
            // 否则里面残留的仓库树会被一并删掉,变成用户的本地仓库永久丢失。
            var stagedItemsRestored = true
            if renamed {
                do {
                    // 回滚同样可能跨卷移动整棵目录树,移出主线程。
                    try await Self.moveItemOffMainThread(fromPath: newPath, toPath: oldPath)
                } catch {
                    editServiceLog.error("event=rollback_rename_failed reason=\(error.localizedDescription)")
                }
                let rollbackBranches = branchRollbacks.map { rollback in
                    WorkplaceEditBranchRollback(
                        path: Self.replacePathPrefix(
                            rollback.path,
                            oldPrefix: newPath,
                            newPrefix: oldPath
                        ),
                        branch: rollback.branch
                    )
                }
                let rollbackStagedRemovals = stagedRemovals.map { item in
                    (
                        originalPath: Self.replacePathPrefix(
                            item.originalPath,
                            oldPrefix: newPath,
                            newPrefix: oldPath
                        ),
                        stagedPath: item.stagedPath
                    )
                }
                do {
                    try await restoreCheckedOutBranches(rollbackBranches)
                } catch {
                    editServiceLog.error("event=rollback_branch_restore_failed reason=\(error.localizedDescription)")
                }
                do {
                    try await restoreStagedItems(rollbackStagedRemovals)
                } catch {
                    editServiceLog.error("event=rollback_restore_failed reason=\(error.localizedDescription)")
                    stagedItemsRestored = false
                }
            } else {
                do {
                    try await restoreCheckedOutBranches(branchRollbacks)
                } catch {
                    editServiceLog.error("event=rollback_branch_restore_failed reason=\(error.localizedDescription)")
                }
                do {
                    try await restoreStagedItems(stagedRemovals)
                } catch {
                    editServiceLog.error("event=rollback_restore_failed reason=\(error.localizedDescription)")
                    stagedItemsRestored = false
                }
            }
            if stagedItemsRestored {
                // 递归删除(暂存目录里可能是整棵仓库树)移出主线程。
                await Self.removeItemOffMainThread(
                    syncCoordinator.fileSystemService,
                    at: removalStagingRoot.path
                )
            } else {
                // 保留暂存目录,用户可从该路径手工取回未还原的仓库目录。
                editServiceLog.error("event=rollback_incomplete staging_root_preserved path=\(removalStagingRoot.path, privacy: .private)")
            }
            throw error
        }
    }

    private func updatedSyncStatePath(
        _ state: RepositorySyncState,
        oldWorkplacePath: String,
        newWorkplacePath: String
    ) throws -> RepositorySyncState {
        guard oldWorkplacePath != newWorkplacePath else { return state }
        try LocalPathSafety.validateManagedPath(
            state.localPath,
            within: oldWorkplacePath
        )
        let oldPrefix = WorkplaceStore.normalizedPath(oldWorkplacePath) + "/"
        let normalizedLocalPath = WorkplaceStore.normalizedPath(state.localPath)
        guard normalizedLocalPath.hasPrefix(oldPrefix) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }

        var updatedState = state
        let suffix = String(normalizedLocalPath.dropFirst(oldPrefix.count))
        updatedState.localPath = URL(fileURLWithPath: newWorkplacePath)
            .appendingPathComponent(suffix)
            .path
        return updatedState
    }

    private func ensureManagedSyncStates(
        _ states: [RepositorySyncState],
        within workplacePath: String
    ) throws {
        for state in states {
            try LocalPathSafety.validateManagedPath(
                state.localPath,
                within: workplacePath
            )
        }
    }

    private func stageLocalItemForRemovalIfExists(
        at path: String,
        stagingRoot: String
    ) async throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let stagingDirectory = URL(fileURLWithPath: stagingRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let stagedPath = stagingDirectory
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            .path
        // 移出到 temp 常常是跨卷移动(退化为复制+删除),耗时可达数分钟,移出主线程。
        try await Self.moveItemOffMainThread(fromPath: path, toPath: stagedPath)
        return stagedPath
    }

    private func repositoryDisplayName(
        for state: RepositorySyncState,
        repositoryNamesByID: [UUID: String]
    ) -> String {
        if let repositoryName = repositoryNamesByID[state.repositoryID] {
            return repositoryName
        }
        return URL(fileURLWithPath: state.localPath).lastPathComponent
    }

    private func performProgressTrackedOperation<Result>(
        with tracker: WorkplaceOperationProgressTracker?,
        repositoryName: String,
        operation: () async throws -> Result
    ) async throws -> Result {
        guard let tracker else {
            return try await operation()
        }

        await tracker.didStart(repositoryName: repositoryName)
        do {
            let result = try await operation()
            await tracker.didFinish(repositoryName: repositoryName)
            return result
        } catch {
            await tracker.didFinish(repositoryName: repositoryName)
            throw error
        }
    }

    private func restoreStagedItems(_ stagedItems: [(originalPath: String, stagedPath: String)]) async throws {
        // 还原同样是整棵仓库树的移动,可能跨卷,移出主线程执行。
        // 只捕获 Sendable 的路径列表,失败信息带回主线程记录。
        let failures = await Task.detached(priority: .userInitiated) {
            () -> [(path: String, reason: String)] in
            var failures: [(path: String, reason: String)] = []
            for item in stagedItems.reversed() {
                guard FileManager.default.fileExists(atPath: item.stagedPath) else { continue }
                let parentDirectory = (item.originalPath as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(
                        atPath: parentDirectory,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try FileManager.default.moveItem(atPath: item.stagedPath, toPath: item.originalPath)
                } catch {
                    failures.append((path: item.originalPath, reason: error.localizedDescription))
                }
            }
            return failures
        }.value

        for failure in failures {
            editServiceLog.error("event=restore_staged_item_failed path=\(failure.path, privacy: .private) reason=\(failure.reason)")
        }
        if let firstFailure = failures.first {
            throw WorkplaceEditServiceError.stagedItemRestoreFailed(
                path: firstFailure.path,
                reason: firstFailure.reason
            )
        }
    }

    private func removeClonedItemsIfNeeded(_ states: [RepositorySyncState]) async throws {
        // 递归删除可能耗时数分钟(参考 WorkplaceRuntimeService.removeItemOffMainThread),
        // 移出主线程执行;只捕获 Sendable 的文件系统服务与路径列表,不捕获 self。
        let fileSystem = syncCoordinator.fileSystemService
        let paths = states.map(\.localPath)
        try await Task.detached(priority: .userInitiated) {
            for path in paths {
                try fileSystem.removeItemIfExists(at: path)
            }
        }.value
    }

    /// 跨目录移动整棵目录树(跨卷时退化为复制+删除)可能耗时很久,移出主线程执行。
    nonisolated private static func moveItemOffMainThread(fromPath: String, toPath: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(atPath: fromPath, toPath: toPath)
        }.value
    }

    /// 递归删除(暂存目录里可能是整棵仓库树)移出主线程执行;尽力而为,失败不抛错。
    nonisolated private static func removeItemOffMainThread(
        _ fileSystem: any FileSystemServicing,
        at path: String
    ) async {
        try? await Task.detached(priority: .userInitiated) {
            try fileSystem.removeItemIfExists(at: path)
        }.value
    }

    private func restoreCheckedOutBranches(
        _ rollbacks: [WorkplaceEditBranchRollback]
    ) async throws {
        var firstError: Error?
        for rollback in rollbacks.reversed() {
            do {
                try await gitService.checkoutBranch(
                    rollback.branch,
                    in: rollback.path
                )
            } catch {
                editServiceLog.error("event=rollback_single_branch_failed path=\(rollback.path) branch=\(rollback.branch) reason=\(error.localizedDescription)")
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private static func replacePathPrefix(
        _ path: String,
        oldPrefix: String,
        newPrefix: String
    ) -> String {
        let normalizedPath = WorkplaceStore.normalizedPath(path)
        let normalizedOldPrefix = WorkplaceStore.normalizedPath(oldPrefix)
        guard normalizedPath.hasPrefix(normalizedOldPrefix) else { return path }
        let suffix = normalizedPath.dropFirst(normalizedOldPrefix.count)
        return newPrefix + suffix
    }
}
