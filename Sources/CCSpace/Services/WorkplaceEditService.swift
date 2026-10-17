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

/// 只登记"克隆真正开始执行"的目标路径:回滚仅删这里——未启动的预期路径可能是用户既有同名目录。
/// 用 actor 承载,因任务体不在 MainActor 上。
private actor StartedClonePathsBox {
    private var paths: [String] = []

    func append(_ path: String) {
        paths.append(path)
    }

    func snapshot() -> [String] {
        paths
    }
}

enum WorkplaceEditServiceError: LocalizedError {
    case stagedItemRestoreFailed(path: String, reason: String)
    /// 原始错误多为 git 英文/系统描述,统一包中文再上抛。
    case branchRollbackFailed(branch: String, reason: String)
    /// 改名被嵌套工作区挡住:整棵树会被移走,子工作区的路径不会随之重映射。
    case nestedWorkplaceBlocksRename(nestedName: String)

    var errorDescription: String? {
        switch self {
        case let .stagedItemRestoreFailed(path, reason):
            return "还原仓库目录失败（\(reason)）。文件仍保留在暂存目录中，可手动取回：\(path)"
        case let .branchRollbackFailed(branch, reason):
            return "回滚分支切换失败（\(reason)）。仓库可能仍停在编辑过程中的分支：\(branch)"
        case let .nestedWorkplaceBlocksRename(nestedName):
            return "该工作区目录内还有子工作区「\(nestedName)」。改名会整体移动目录，子工作区记录的本地路径不会自动跟随，会导致其状态丢失；请先修改或删除子工作区后再改名"
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
        // 记录在 await 窗口内被磁盘刷新等路径删除时必须报错,不能静默"保存成功"。
        guard let originalWorkplace = workplaceStore.workplaces.first(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }
        // 勾选清单按**当前仓库池**过滤后再算差异:旧 id 原样写回等于复活悬空引用(池可能已 removeRepository),
        // 之后没有 UI 入口能清掉;过滤必须在差异计算之前。
        let liveRepositoryIDs = Set(repositoryStore.repositories.map(\.id))
        let selectedRepositoryIDs = selectedRepositoryIDs.filter { liveRepositoryIDs.contains($0) }
        guard selectedRepositoryIDs.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }
        let validatedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBranch = normalizedBranch?.isEmpty == true ? nil : normalizedBranch

        let currentSelectedIDs = Set(originalWorkplace.selectedRepositoryIDs)
        let nextSelectedIDs = Set(selectedRepositoryIDs)
        let removedRepositoryIDs = currentSelectedIDs.subtracting(nextSelectedIDs)
        let addedRepositoryIDs = nextSelectedIDs.subtracting(currentSelectedIDs)
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplaceID }
        // 循环构建字典:重复 id 时后者覆盖前者,不用会 trap 的 Dictionary(uniqueKeysWithValues:)。
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

        // 大小写归一比较:默认卷大小写不敏感,仅大小写不同的改名指向同一目录,严格比较会误报重名。
        let normalizedNewPath = WorkplaceStore.normalizedPath(newPath)
        let lowercasedNewPath = normalizedNewPath.lowercased()
        guard !workplaceStore.workplaces.contains(where: {
            $0.id != workplaceID &&
            WorkplaceStore.normalizedPath($0.path).lowercased() == lowercasedNewPath
        }) else {
            throw WorkplaceStoreError.duplicatePath
        }
        // 存在性探测挪到主线程之外:目标路径可能在网盘/外置盘上,单次 stat 也能阻塞主线程数秒。
        let targetExistsOnDisk: Bool = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: newPath)
        }.value
        // 与上方重名检查同口径:默认卷上"仅大小写不同"的改名指向同一目录,`fileExists` 恒为真,
        // 严格相等会把合法改名误报成"路径已存在"(并让下面 pathsDifferIgnoringCase 分支永不可达)。
        let normalizedOldPath = WorkplaceStore.normalizedPath(oldPath)
        guard normalizedNewPath.lowercased() == normalizedOldPath.lowercased() ||
                targetExistsOnDisk == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }
        try ensureManagedSyncStates(originalStates, within: oldPath)

        // 改名会移走整棵 oldPath:树内若住着其它工作区,其 localPath 不会随移动重映射,磁盘刷新会按
        // "目录缺失"整条删掉子工作区(不可恢复)——触碰磁盘前先 fail-closed。containment 用大小写归一路径。
        let renamed = newPath != oldPath
        let pathsDifferIgnoringCase =
            normalizedNewPath.lowercased() != normalizedOldPath.lowercased()
        if renamed, pathsDifferIgnoringCase, let nested = workplaceStore.workplaces.first(where: { candidate in
            candidate.id != workplaceID
                && LocalPathSafety.isWithinDirectory(candidate.path, rootPath: oldPath)
        }) {
            throw WorkplaceEditServiceError.nestedWorkplaceBlocksRename(nestedName: nested.name)
        }

        // ── 磁盘刷新豁免(必须先于任何磁盘改动)─────────────────────────────
        // 被移出→.removing、保留→.switching 全置瞬态:此刻记录仍指 oldPath 而目录可能已整树移走,
        // diskRefreshResult 对含瞬态行的工作区豁免删除(isWorkplaceOperationInFlight),回滚用 originalStates 还原。
        workplaceStore.setSyncStatus(.removing, for: workplaceID, repositoryIDs: removedRepositoryIDs)
        workplaceStore.setSyncStatus(.switching, for: workplaceID, repositoryIDs: nextSelectedIDs)

        let removalStagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-space-edit-\(UUID().uuidString)", isDirectory: true)
        var stagedRemovals: [(originalPath: String, stagedPath: String)] = []
        var clonedStates: [RepositorySyncState] = []
        // 预期克隆目标路径清单只用于罩锁(锁 key 精确匹配);删除范围另取"克隆已启动"清单。
        var cloneTargetPaths: [String] = []
        let startedClonePathsBox = StartedClonePathsBox()
        var branchRollbacks: [WorkplaceEditBranchRollback] = []

        do {
            if renamed {
                // 目录移动要与仓库级写操作互斥:锁 key 精确匹配,须罩住旧/新目录本身、两侧全部仓库路径,
                // 并按磁盘现状罩住树内其它工作区的状态行路径(漏锁的代价是仓库被写坏;跨卷 move 退化为复制+删除)。
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
                renameLockPaths.append(contentsOf: workplaceStore.syncStates.compactMap { candidate in
                    LocalPathSafety.isWithinDirectory(candidate.localPath, rootPath: oldPath)
                        ? candidate.localPath
                        : nil
                })
                // 整棵工作区目录的移动(跨卷时退化为"复制+删除")可能耗时很久,必须移出主线程。
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
                            // 与后台定时 pull/push 互斥,避免对同一工作树交错写;闭包内只做 git 操作,
                            // 切出的原分支带出来再记录,避免捕获 MainActor 状态。
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
                        retainedStates[index].lastError = UserFacingError.message(for: error)
                        retainedStates[index].status = .failed
                    }
                }
            }

            if addedRepositoryIDs.isEmpty == false {
                let addedRepositories = repositoryStore.repositories.filter { addedRepositoryIDs.contains($0.id) }
                if addedRepositories.isEmpty == false {
                    // 克隆要与后台定时 pull/push 互斥:锁 key 精确匹配,只锁工作区根罩不住仓库级写操作,
                    // 必须连同每条待克隆的目标路径一起加锁;闭包非 MainActor,只可捕获 Sendable 值副本。
                    let workplaceForClone = updatedWorkplace
                    var expectedClonePaths: [String] = []
                    for repository in addedRepositories {
                        expectedClonePaths.append(
                            try WorkplaceStore.repositoryPath(
                                workplacePath: newPath,
                                repositoryName: repository.repoName
                            )
                        )
                    }
                    // oldPath 也必须入锁:此刻记录仍指 oldPath,磁盘刷新的锁快照含 canonical(oldPath)
                    // 时 isWorkplaceOperationInFlight 才豁免该工作区(克隆数分钟,期间目录"缺失"是正常的)。
                    var cloneLockPaths = [newPath, oldPath]
                    cloneLockPaths.append(contentsOf: expectedClonePaths)
                    // 进入克隆前先登记预期路径(锁等待期间被取消也要罩住这些目录)。
                    cloneTargetPaths = expectedClonePaths
                    clonedStates = try await RepositoryOperationLock.shared.withLockPaths(cloneLockPaths) {
                        try await syncCoordinator.cloneRepositories(
                            repositories: addedRepositories,
                            workplace: workplaceForClone,
                            progressHandler: progressHandler,
                            onCloneStarted: { startedPath in
                                await startedClonePathsBox.append(startedPath)
                            }
                        )
                    }
                    retainedStates.append(contentsOf: clonedStates)
                }
            }

            // 落库前与 Store 的**最新行**做字段增量合并(`RepositorySyncState.merging`):克隆/切分支跑数分钟,期间
            // 磁盘刷新与后台 pull 的回写会被整行替换覆盖(lost update)。localPath 例外:本操作拥有,须在本轮结果路径落笔。
            let liveStates = workplaceStore.syncStates.filter { $0.workplaceID == workplaceID }
            let mergedStates: [RepositorySyncState] = retainedStates.map { updated in
                guard let original = originalStates.first(where: { $0.repositoryID == updated.repositoryID }),
                      let latest = liveStates.first(where: { $0.repositoryID == updated.repositoryID }) else {
                    return updated
                }
                var merged = RepositorySyncState.merging(
                    updated: updated,
                    onto: original,
                    in: latest,
                    // 入口把本轮保留行预标为 .switching,收口必须声明该瞬态归本操作所有:
                    // 否则"结果恰好等于快照"的行会把 .switching 原样落库,永久停在转轮直到重启。
                    premarkedTransient: .switching
                ) ?? latest
                merged.localPath = updated.localPath
                return merged
            }

            try workplaceStore.applyWorkplaceEdit(updatedWorkplace, syncStates: mergedStates)
            // 暂存根目录里可能装着多棵被移出的仓库树,递归删除必须移出主线程。
            await Self.removeItemOffMainThread(
                syncCoordinator.fileSystemService,
                at: removalStagingRoot.path
            )
        } catch {
            // 取消/失败回滚:只删除"克隆已启动"的目录;预期清单继续用于罩锁路径。
            let startedClonePaths = await startedClonePathsBox.snapshot()
            await performEditRollback(
                renamed: renamed,
                oldPath: oldPath,
                newPath: newPath,
                cloneTargetPaths: cloneTargetPaths,
                startedClonePaths: startedClonePaths,
                branchRollbacks: branchRollbacks,
                stagedRemovals: stagedRemovals,
                removalStagingRoot: removalStagingRoot
            )
            // 状态回滚用入口快照原样恢复;记录若已在 await 窗口内被并发删除,不得补写孤儿行,只留痕。
            if workplaceStore.workplaces.contains(where: { $0.id == workplaceID }) {
                workplaceStore.replaceSyncStates(originalStates, for: workplaceID)
            } else {
                editServiceLog.error(
                    "event=edit_state_rollback_skipped reason=workplace_record_missing workplace_id=\(workplaceID)"
                )
            }
            throw error
        }
    }

    /// 回滚同样必须持锁:等锁的 pull/push 若趁回滚移动目录/切分支时插入,会对同一工作树交错写;
    /// 锁获取本身被取消时降级为无锁尽力回滚(原始错误往往就来自取消,回滚不能再等待)。
    private func performEditRollback(
        renamed: Bool,
        oldPath: String,
        newPath: String,
        cloneTargetPaths: [String],
        startedClonePaths: [String],
        branchRollbacks: [WorkplaceEditBranchRollback],
        stagedRemovals: [(originalPath: String, stagedPath: String)],
        removalStagingRoot: URL
    ) async {
        let lock = RepositoryOperationLock.shared
        var rollbackLockPaths = [oldPath, newPath]
        rollbackLockPaths += cloneTargetPaths
        for item in stagedRemovals {
            rollbackLockPaths += [
                item.originalPath,
                Self.replacePathPrefix(item.originalPath, oldPrefix: newPath, newPrefix: oldPath),
            ]
        }
        for rollback in branchRollbacks {
            rollbackLockPaths += [
                rollback.path,
                Self.replacePathPrefix(rollback.path, oldPrefix: newPath, newPrefix: oldPath),
            ]
        }
        var rollbackLocksAcquired: [String] = []
        // 必须与 withLockPaths 同一排序(RepositoryOperationLock.canonicalLockOrder):按原始路径
        // 排序与按 canonical key 排序可能不一致(symlink 别名/大小写),顺序反转会造成环形等待死锁。
        let rollbackLockKeys = RepositoryOperationLock.canonicalLockOrder(rollbackLockPaths)
        for key in rollbackLockKeys {
            do {
                try await lock.acquire(path: key)
                rollbackLocksAcquired.append(key)
            } catch {
                // 等待中被取消:放弃继续收集,带已拿到的锁开始回滚。
                editServiceLog.error("event=rollback_lock_acquire_stopped reason=\(error.localizedDescription)")
                break
            }
        }
        // 锁按序显式释放:本函数所有失败路径都在内部 catch,不会中途 throw(defer 里只能 fire-and-forget)。
        do {
            // 递归删除整棵已克隆仓库目录可能耗时很久,必须移出主线程;入参只能是"克隆已启动"清单。
            try await removeClonedItemsIfNeeded(startedClonePaths)
        } catch {
            editServiceLog.error("event=rollback_cleanup_failed reason=\(error.localizedDescription)")
        }
        // 暂存根目录里可能装着多棵被移出的仓库树,只有全部还原成功才允许清理,否则用户的本地仓库永久丢失。
        var stagedItemsRestored = true
        if renamed {
            var renameRolledBack = true
            do {
                try await Self.moveItemOffMainThread(fromPath: newPath, toPath: oldPath)
            } catch {
                renameRolledBack = false
                editServiceLog.fault("event=rollback_rename_failed reason=\(error.localizedDescription)")
            }
            if renameRolledBack {
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
                // 目录树仍在 newPath 下:按 oldPath 做的分支恢复/暂存还原注定级联失败,
                // 短路保留现场,暂存目录一律不删。
                stagedItemsRestored = false
                editServiceLog.fault("event=rollback_short_circuited reason=directory_still_at_new_path path=\(newPath, privacy: .private)")
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
            await Self.removeItemOffMainThread(
                syncCoordinator.fileSystemService,
                at: removalStagingRoot.path
            )
        } else {
            // 还原不完整:保留暂存目录供用户手工取回。
            editServiceLog.error("event=rollback_incomplete staging_root_preserved path=\(removalStagingRoot.path, privacy: .private)")
        }
        for path in rollbackLocksAcquired.reversed() {
            await lock.release(path: path)
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
            // 严格包含:状态行 localPath 不得等于工作区根,否则整树改名/暂存移出会动到根本身。
            try LocalPathSafety.validateStrictlyContainedPath(
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
        // 整棵仓库树的移动可能跨卷,移出主线程;闭包只捕获 Sendable 路径列表。
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
                    // 该 reason 会拼进 stagedItemRestoreFailed 的用户可见文案,统一走中文入口。
                    failures.append((path: item.originalPath, reason: UserFacingError.message(for: error)))
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

    private func removeClonedItemsIfNeeded(_ paths: [String]) async throws {
        // 递归删除可能耗时数分钟,必须移出主线程;闭包只捕获 Sendable 的服务与路径,不捕获 self。
        let fileSystem = syncCoordinator.fileSystemService
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
        // 失败必须留痕:删的可能是整棵仓库树,静默失败会把完整副本永久留在临时目录。
        await Task.detached(priority: .userInitiated) {
            do {
                try fileSystem.removeItemIfExists(at: path)
            } catch {
                editServiceLog.error(
                    "event=staging_cleanup_failed path=\(path, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }

    private func restoreCheckedOutBranches(
        _ rollbacks: [WorkplaceEditBranchRollback]
    ) async throws {
        guard rollbacks.isEmpty == false else { return }
        let gitService = gitService
        // 回滚必须脱离调用方的取消上下文:正向编辑常因用户取消而失败,回滚若仍在已取消的
        // 任务里跑,checkout 会直接抛 CancellationError、一次都切不回去,分支停在编辑中途。
        let failures = await Task.detached(priority: .userInitiated) {
            () -> [(path: String, branch: String, reason: String)] in
            var failures: [(path: String, branch: String, reason: String)] = []
            for rollback in rollbacks.reversed() {
                do {
                    try await gitService.checkoutBranch(rollback.branch, in: rollback.path)
                } catch {
                    failures.append((
                        path: rollback.path,
                        branch: rollback.branch,
                        reason: UserFacingError.message(for: error)
                    ))
                }
            }
            return failures
        }.value

        for failure in failures {
            editServiceLog.error("event=rollback_single_branch_failed path=\(failure.path) branch=\(failure.branch) reason=\(failure.reason)")
        }
        if let first = failures.first {
            throw WorkplaceEditServiceError.branchRollbackFailed(
                branch: first.branch,
                reason: first.reason
            )
        }
    }

    private static func replacePathPrefix(
        _ path: String,
        oldPrefix: String,
        newPrefix: String
    ) -> String {
        let normalizedPath = WorkplaceStore.normalizedPath(path)
        let normalizedOldPrefix = WorkplaceStore.normalizedPath(oldPrefix)
        // 前缀必须落在**目录边界**上:`/root/ws2/repo` 对 `/root/ws` 同样 hasPrefix,按前缀替换会产出错误重映射。
        let suffix: String
        if normalizedPath == normalizedOldPrefix {
            suffix = ""
        } else if normalizedPath.hasPrefix(normalizedOldPrefix + "/") {
            suffix = String(normalizedPath.dropFirst(normalizedOldPrefix.count))
        } else {
            return path
        }
        return newPrefix + suffix
    }
}
