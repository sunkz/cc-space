import Foundation
import os

private let workplaceRuntimeLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceRuntimeService"
)

@MainActor
struct WorkplaceRuntimeService {
    nonisolated private static let maxConcurrentBatchTasks = 4

    /// 手动 Stash 的消息前缀,与切分支安全流程的自动 Stash 消息区分。
    nonisolated private static let manualStashMessage = "CCSpace manual stash"

    /// 批量操作中等待仓库锁时被取消的失败文案。
    nonisolated private static let lockCancelledMessage = "操作已取消"

    let workplaceStore: WorkplaceStore
    let syncCoordinator: SyncCoordinator
    let workplaceRootPath: String

    init(
        workplaceStore: WorkplaceStore,
        syncCoordinator: SyncCoordinator,
        workplaceRootPath: String = ""
    ) {
        self.workplaceStore = workplaceStore
        self.syncCoordinator = syncCoordinator
        self.workplaceRootPath = workplaceRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pullRepositories(in workplace: Workplace, repositoryID: UUID? = nil) async -> RepositoryPullResult {
        guard isManagedWorkplace(workplace) else {
            return RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 0)
        }

        let targetStates = managedStates(
            in: workplace,
            repositoryID: repositoryID,
            requiresLocalDirectory: true
        )
        return await syncCoordinator.pullRepositories(
            syncStates: targetStates,
            workplaceStore: workplaceStore
        )
    }

    func retryClone(repository: RepositoryConfig, in workplace: Workplace) async throws {
        try ensureManagedWorkplace(workplace)
        let localPath = try WorkplaceStore.repositoryPath(
            workplacePath: workplace.path,
            repositoryName: repository.repoName
        )

        // 与 push/切分支/拉取共用 per-path 锁:从删除半成品目录到 clone 完成,
        // 整段都不允许同路径其他写操作进入(clone 自身不加锁,必须在这里罩住;
        // 否则锁一释放,pull/push 就能插进克隆到一半的目录)。
        let fileSystemService = syncCoordinator.fileSystemService
        let lock = RepositoryOperationLock.shared
        try await lock.acquire(path: localPath)
        // 持锁后立即把该行标为 .cloning 瞬态:删目录→克隆要数分钟,没有瞬态的话,
        // 磁盘刷新会把这行归为"本地仓库缺失"的假失败(现在瞬态行被刷新豁免)。
        workplaceStore.setSyncStatus(.cloning, for: workplace.id, repositoryIDs: [repository.id])
        let retriedStates: [RepositorySyncState]
        do {
            try await Self.removeItemOffMainThread(fileSystemService, at: localPath)
            retriedStates = try await syncCoordinator.cloneRepositories(
                repositories: [repository],
                workplace: workplace
            )
        } catch {
            await lock.release(path: localPath)
            // 瞬态必须归位成本轮失败:本进程内没有任何驱动器会把 .cloning 改回终态
            // (重启归位在解码路径,帮不了还活着的这次会话)。
            if var row = workplaceStore.syncStates.first(where: {
                $0.workplaceID == workplace.id && $0.repositoryID == repository.id
            }) {
                row.status = .failed
                row.lastError = error.localizedDescription
                row.hasLocalDirectory = FileManager.default.fileExists(atPath: localPath)
                workplaceStore.updateSyncStates([row])
            }
            throw error
        }
        await lock.release(path: localPath)

        // 按 key 增量更新,而不是拿 await 之后的快照整体替换:
        // clone 可能耗时数分钟,期间定时磁盘刷新 / 单仓库 push 写入的状态
        // 会被这份快照整体覆盖(lost update)。
        workplaceStore.updateSyncStates(retriedStates)
    }

    func pushRepositories(in workplace: Workplace) async throws -> RepositoryPushResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        let results: [BatchPushOperationResult] = await runConcurrentStateOperations(
            states,
            onLockCancelled: { state in
                .failed(Self.failedState(from: state, errorMessage: Self.lockCancelledMessage))
            },
            onUnexpectedLockError: { state, error in
                .failed(Self.failedState(from: state, errorMessage: error.localizedDescription))
            }
        ) { state in
            do {
                guard try await Self.shouldPushRepository(state, gitService: gitService) else {
                    return .skipped(Self.normalizedSkippedPushState(from: state))
                }

                try await gitService.push(in: state.localPath)
                return .pushed(Self.succeededState(from: state, touchLastSyncedAt: true))
            } catch {
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        // 持久化走防抖写盘,不会失败,直接落库即可。
        workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let summary = results.summarize()
        return RepositoryPushResult(
            successCount: summary.successCount,
            failedCount: summary.failedCount,
            skippedCount: summary.skippedCount,
            failedNames: summary.failedNames
        )
    }

    func pushRepository(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> RepositoryPushOutcome {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            let pushed = try await RepositoryOperationLock.shared.withLock(path: state.localPath) { () -> Bool in
                guard try await Self.shouldPushRepository(state, gitService: gitService) else {
                    return false
                }
                try await gitService.push(in: state.localPath)
                return true
            }
            guard pushed else {
                // 跳过也按成功口径回写,清掉陈旧的失败标记(静态归一化 + 尽力落库)。
                persistSuccessState(Self.normalizedSkippedPushState(from: state))
                return .skipped
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastSyncedAt = .now
            updatedState.lastError = nil
            persistSuccessState(updatedState)
            return .pushed
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    func switchBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        to branch: String
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService

        // "切换中"立即落库:远端分支切换可能带一次单 ref fetch(网络,数秒),
        // 行上必须马上出现转轮——否则只有详情页工具栏角落一个不显眼的指示器。
        // 成功/失败路径末尾会回写终态;进程被杀则由解码兜底归位 .idle。
        workplaceStore.setSyncStatus(.switching, for: state.workplaceID, repositoryIDs: [state.repositoryID])

        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                if await Self.isCurrentBranch(trimmedBranch, for: state, gitService: gitService) {
                    return
                }

                try await GitWorktreeSafety.withCleanWorkingTree(
                    in: state.localPath,
                    gitService: gitService,
                    blockedOperation: .switchBranch
                ) {
                    try await gitService.checkoutBranch(trimmedBranch, in: state.localPath)
                }
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    func switchRepositoryToWorkBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        workBranch: String
    ) async throws -> String {
        let trimmedBranch = workBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }

        try await switchBranch(for: state, in: workplace, to: trimmedBranch)
        return trimmedBranch
    }

    func switchRepositoryToDefaultBranch(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> String {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
            throw WorkplaceRuntimeServiceError.missingDefaultBranch
        }

        try await switchBranch(for: state, in: workplace, to: defaultBranch)
        return defaultBranch
    }

    /// 创建分支并切换(脏工作区的改动会原样带到新分支,无需 Stash);
    /// base 为 nil 时基于仓库当前 HEAD(等价 `git checkout -b`),否则基于该分支。
    func createBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        to branch: String,
        base: BranchBaseKind = .currentHead
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                switch base {
                case .currentHead:
                    try await gitService.createLocalBranch(trimmedBranch, in: state.localPath)
                case .localBranch(let baseBranch):
                    let trimmedBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedBase.isEmpty {
                        // 基线空白视为未指定:与旧行为一致,从 HEAD 创建。
                        try await gitService.createLocalBranch(trimmedBranch, in: state.localPath)
                    } else {
                        try await gitService.createBranch(trimmedBranch, fromRev: trimmedBase, in: state.localPath)
                    }
                case .remoteBranch(let baseBranch):
                    let trimmedBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedBase.isEmpty {
                        try await gitService.createLocalBranch(trimmedBranch, in: state.localPath)
                    } else {
                        try await gitService.createBranch(
                            fromRemoteBranch: trimmedBranch,
                            baseBranch: trimmedBase,
                            in: state.localPath
                        )
                    }
                }
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 删除本地分支;当前分支不可删除(界面已隐藏入口,这里兜底给出明确报错)。
    func deleteBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        branch: String
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                if await Self.isCurrentBranch(trimmedBranch, for: state, gitService: gitService) {
                    throw WorkplaceRuntimeServiceError.cannotDeleteCurrentBranch
                }
                try await gitService.deleteLocalBranch(trimmedBranch, in: state.localPath)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 删除远端分支(向 origin 推送删除引用,影响所有协作者;界面已二次确认)。
    func deleteRemoteBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        branch: String
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                try await gitService.deleteRemoteBranch(trimmedBranch, in: state.localPath)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 手动 Stash 当前改动(含 untracked)。
    func stashChanges(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                // 干净工作区下 `git stash push` 不报错也不产生 Stash,提前给出明确提示。
                guard let branchStatus = await gitService.branchStatus(in: state.localPath) else {
                    throw WorkplaceRuntimeServiceError.unreadableGitStatus
                }
                guard branchStatus.hasUncommittedChanges else {
                    throw WorkplaceRuntimeServiceError.nothingToStash
                }

                try await gitService.stashPush(in: state.localPath, message: Self.manualStashMessage)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 恢复指定位置的 Stash 并从列表移除;冲突时 Stash 会被 git 保留。
    func popStash(
        at index: Int,
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                try await gitService.popStash(at: index, in: state.localPath)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 删除指定位置的 Stash,不可恢复。
    func dropStash(
        at index: Int,
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                try await gitService.dropStash(at: index, in: state.localPath)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    /// 中止单仓库进行中的合并/变基等操作(调用方需已二次确认),返回被中止的操作。
    func abortInterruptedOperation(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> GitInterruptedOperation {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            let operation = try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                try await gitService.abortInterruptedOperation(in: state.localPath)
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
            return operation
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    func switchRepositoriesToWorkBranch(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let trimmedBranch = workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }

        return try await switchRepositoriesToBranch(trimmedBranch, in: workplace)
    }

    /// 所有仓库切换到同一分支;本地不存在该分支时,经 `checkoutBranch` 回退链
    /// 跟踪远端同名分支或从当前 HEAD 新建(批量"新建分支"入口)。
    func switchRepositoriesToBranch(
        _ branch: String,
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }

        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        return await switchRepositories(states) { _ in
            .success(trimmedBranch)
        }
    }

    func switchRepositoriesToDefaultBranch(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        return await switchRepositories(states) { state in
            guard let branch = await gitService.defaultBranch(in: state.localPath) else {
                return .failure(WorkplaceRuntimeServiceError.missingDefaultBranch.localizedDescription)
            }
            return .success(branch)
        }
    }

    func mergeDefaultBranchIntoCurrent(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        let results: [BatchMergeOperationResult] = await runConcurrentStateOperations(
            states,
            onLockCancelled: { state in
                .failed(Self.failedState(from: state, errorMessage: Self.lockCancelledMessage))
            },
            onUnexpectedLockError: { state, error in
                .failed(Self.failedState(from: state, errorMessage: error.localizedDescription))
            }
        ) { state in
            do {
                if await Self.shouldSkipMergeDefaultBranch(for: state, gitService: gitService) {
                    return .skipped(Self.succeededState(from: state))
                }

                try await GitWorktreeSafety.withCleanWorkingTree(
                    in: state.localPath,
                    gitService: gitService,
                    blockedOperation: .mergeDefaultBranchIntoCurrent
                ) {
                    _ = try await gitService.mergeDefaultBranchIntoCurrent(in: state.localPath)
                }
                return .merged(Self.succeededState(from: state))
            } catch {
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        // 持久化走防抖写盘,不会失败,直接落库即可。
        workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let summary = results.summarize()
        return WorkplaceBulkBranchSwitchResult(
            successCount: summary.successCount,
            failedCount: summary.failedCount,
            skippedCount: summary.skippedCount,
            failedNames: summary.failedNames
        )
    }

    func mergeDefaultBranchIntoCurrent(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> GitMergeDefaultBranchOutcome {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService

        do {
            let outcome = try await RepositoryOperationLock.shared.withLock(path: state.localPath) { () -> GitMergeDefaultBranchOutcome in
                if await Self.shouldSkipMergeDefaultBranch(for: state, gitService: gitService) {
                    return .skipped
                }

                try await GitWorktreeSafety.withCleanWorkingTree(
                    in: state.localPath,
                    gitService: gitService,
                    blockedOperation: .mergeDefaultBranchIntoCurrent
                ) {
                    _ = try await gitService.mergeDefaultBranchIntoCurrent(in: state.localPath)
                }
                return .merged
            }
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            persistSuccessState(updatedState)
            return outcome
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            persistFailureState(updatedState)
            throw error
        }
    }

    func deleteWorkplace(_ workplace: Workplace, removeLocalDirectories: Bool) async throws {
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }

        if removeLocalDirectories {
            do {
                try ensureManagedWorkplace(workplace)
            } catch {
                let deleteError = WorkplaceDeletionError.unmanagedPath(
                    workplacePath: workplace.path,
                    rootPath: workplaceRootPath
                )
                workplaceRuntimeLog.error(
                    "event=delete_workplace_blocked root_path=\(self.workplaceRootPath, privacy: .public) workplace_path=\(workplace.path, privacy: .public)"
                )
                throw deleteError
            }
            let repoIDs = Set(originalStates.map(\.repositoryID))
            workplaceStore.setSyncStatus(.removing, for: workplace.id, repositoryIDs: repoIDs)

            do {
                // 删除整棵工作区目录必须与 pull/push/切分支等写路径互斥:否则并发
                // 操作会打进正在被删除的目录(读到一半消失的 .git、写进已删目录)。
                // 锁 key 是精确匹配,只锁工作区根路径罩不住仓库级写操作,
                // 必须把目录自身与树内每条仓库 localPath 一起加锁。
                let fileSystemService = syncCoordinator.fileSystemService
                let workplacePath = workplace.path
                // 树内锁路径取"所有 localPath 落在被删目录之下"的同步状态行,
                // 而不是只取本工作区的行:项目显式支持嵌套工作区(A 内可有 A/B),
                // 递归删除同样会打进子工作区仓库的 pull/push,这些行也必须罩住。
                let containedStatePaths = workplaceStore.syncStates.compactMap { candidate -> String? in
                    LocalPathSafety.isWithinDirectory(candidate.localPath, rootPath: workplacePath)
                        ? candidate.localPath
                        : nil
                }
                let lockedPaths = [workplacePath]
                    + originalStates.map(\.localPath)
                    + containedStatePaths
                try await RepositoryOperationLock.shared.withLockPaths(lockedPaths) {
                    // 整棵工作区目录树的递归删除可能耗时数分钟,移出主线程执行。
                    try await Self.removeItemOffMainThread(
                        fileSystemService,
                        at: workplacePath
                    )
                }
            } catch {
                // 状态回滚走防抖写盘,不会失败;若未来引入可失败路径,此处必须留痕,
                // 否则状态会长期停在 .removing,UI 上表现为"一直进行中"。
                workplaceStore.replaceSyncStates(originalStates, for: workplace.id)
                let deleteError = WorkplaceDeletionError.fromRemovalError(
                    error,
                    path: workplace.path
                )
                workplaceRuntimeLog.error(
                    "event=delete_workplace_remove_failed workplace_path=\(workplace.path, privacy: .public) reason=\(deleteError.localizedDescription, privacy: .public)"
                )
                throw deleteError
            }
        }

        try workplaceStore.deleteWorkplace(workplace.id)
    }

    private func ensureManagedWorkplace(_ workplace: Workplace) throws {
        try LocalPathSafety.validateManagedPath(
            workplace.path,
            within: workplaceRootPath
        )
    }

    private func ensureManagedLocalRepositoryExists(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) throws {
        try ensureManagedWorkplace(workplace)
        try LocalPathSafety.validateManagedPath(
            state.localPath,
            within: workplace.path
        )
        guard state.hasLocalDirectory else {
            throw WorkplaceRuntimeServiceError.missingLocalRepository
        }
    }

    private func isManagedWorkplace(_ workplace: Workplace) -> Bool {
        if workplaceRootPath.isEmpty {
            workplaceRuntimeLog.warning("event=empty_root_path workplace_id=\(workplace.id) action=skipped")
            return false
        }
        return LocalPathSafety.isWithinDirectory(
            workplace.path,
            rootPath: workplaceRootPath
        )
    }

    private func managedStates(
        in workplace: Workplace,
        repositoryID: UUID? = nil,
        requiresLocalDirectory: Bool
    ) -> [RepositorySyncState] {
        workplaceStore.syncStates.filter { state in
            guard state.workplaceID == workplace.id else { return false }
            guard repositoryID == nil || state.repositoryID == repositoryID else { return false }
            guard LocalPathSafety.isWithinDirectory(state.localPath, rootPath: workplace.path) else {
                return false
            }
            return requiresLocalDirectory == false || state.hasLocalDirectory
        }
    }

    private func switchableStates(in workplace: Workplace) -> [RepositorySyncState] {
        managedStates(in: workplace, requiresLocalDirectory: true)
    }

    nonisolated private static func shouldPushRepository(
        _ state: RepositorySyncState,
        gitService: GitServicing
    ) async throws -> Bool {
        guard let branchStatus = await gitService.branchStatus(in: state.localPath) else {
            throw WorkplaceRuntimeServiceError.unreadableGitStatus
        }

        return branchStatus.hasUnpushedCommits || branchStatus.hasRemoteTrackingBranch == false
    }

    /// git 操作成功后的状态回写尽力而为:持久化走防抖写盘不会失败,直接落库
    /// (不推翻已成功的操作结果,否则用户会看到"推送失败",但实际远端已收到推送)。
    private func persistSuccessState(_ state: RepositorySyncState) {
        workplaceStore.updateSyncState(state)
    }

    /// git 操作失败后的状态回写同样尽力而为:持久化走防抖写盘不会失败,直接落库,
    /// 不改变抛给用户的错误。
    private func persistFailureState(_ state: RepositorySyncState) {
        workplaceStore.updateSyncState(state)
    }

    /// 递归删除目录(大仓库可能耗时数分钟),放到主线程之外执行,避免冻结 UI。
    nonisolated private static func removeItemOffMainThread(
        _ fileSystem: any FileSystemServicing,
        at path: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try fileSystem.removeItemIfExists(at: path)
        }.value
    }

    private func switchRepositories(
        _ states: [RepositorySyncState],
        resolveBranch: @escaping @Sendable (RepositorySyncState) async -> BatchBranchResolutionResult
    ) async -> WorkplaceBulkBranchSwitchResult {
        let gitService = syncCoordinator.gitService
        let results: [BatchBranchSwitchOperationResult] = await runConcurrentStateOperations(
            states,
            onLockCancelled: { state in
                .failed(Self.failedState(from: state, errorMessage: Self.lockCancelledMessage))
            },
            onUnexpectedLockError: { state, error in
                .failed(Self.failedState(from: state, errorMessage: error.localizedDescription))
            }
        ) { state in
            switch await resolveBranch(state) {
            case .success(let branch):
                do {
                    if await Self.isCurrentBranch(branch, for: state, gitService: gitService) {
                        return .skipped(Self.succeededState(from: state))
                    }

                    // 单仓库粒度的"切换中"转轮,与单仓切换一致;最终结果在闭包外统一回写。
                    // 闭包非 MainActor,Store 在主线程,经 MainActor.run 中转。
                    let workplaceID = state.workplaceID
                    let repositoryID = state.repositoryID
                    await MainActor.run {
                        workplaceStore.setSyncStatus(
                            .switching,
                            for: workplaceID,
                            repositoryIDs: [repositoryID]
                        )
                    }

                    try await GitWorktreeSafety.withCleanWorkingTree(
                        in: state.localPath,
                        gitService: gitService,
                        blockedOperation: .switchBranch
                    ) {
                        try await gitService.checkoutBranch(branch, in: state.localPath)
                    }
                    return .success(Self.succeededState(from: state))
                } catch {
                    return .failed(
                        Self.failedState(
                            from: state,
                            errorMessage: error.localizedDescription
                        )
                    )
                }
            case .failure(let message):
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: message
                    )
                )
            }
        }

        // 持久化走防抖写盘,不会失败,直接落库即可。
        workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let summary = results.summarize()
        return WorkplaceBulkBranchSwitchResult(
            successCount: summary.successCount,
            failedCount: summary.failedCount,
            skippedCount: summary.skippedCount,
            failedNames: summary.failedNames
        )
    }

    private func runConcurrentStateOperations<Result: Sendable>(
        _ states: [RepositorySyncState],
        onLockCancelled: @escaping @Sendable (RepositorySyncState) -> Result,
        onUnexpectedLockError: @escaping @Sendable (RepositorySyncState, any Error) -> Result,
        operation: @escaping @Sendable (RepositorySyncState) async -> Result
    ) async -> [Result] {
        let repoLock = RepositoryOperationLock.shared
        return await ConcurrencyUtilities.runLimitedTasks(
            states,
            maxConcurrentTasks: Self.maxConcurrentBatchTasks
        ) { state in
            do {
                return try await repoLock.withLock(path: state.localPath) {
                    await operation(state)
                }
            } catch is CancellationError {
                // 等锁期间任务被取消:操作未执行,由调用方给出取消语义的结果。
                return onLockCancelled(state)
            } catch {
                // 其余错误(锁自身异常等)不能冒充"已取消"——那会把真实失败静默
                // 报成取消;留痕后交由调用方落成失败态。
                workplaceRuntimeLog.error(
                    "event=concurrent_operation_unexpected_error reason=\(error.localizedDescription)"
                )
                return onUnexpectedLockError(state, error)
            }
        }
    }

    nonisolated private static func succeededState(
        from state: RepositorySyncState,
        touchLastSyncedAt: Bool = false
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .success
        updatedState.lastError = nil
        if touchLastSyncedAt {
            updatedState.lastSyncedAt = .now
        }
        return updatedState
    }

    nonisolated private static func failedState(
        from state: RepositorySyncState,
        errorMessage: String
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .failed
        updatedState.lastError = errorMessage
        return updatedState
    }

    nonisolated private static func normalizedSkippedPushState(
        from state: RepositorySyncState
    ) -> RepositorySyncState {
        guard state.status != .success || state.lastError != nil else {
            return state
        }

        var updatedState = state
        updatedState.status = .success
        updatedState.lastError = nil
        return updatedState
    }

    nonisolated private static func isCurrentBranch(
        _ branch: String,
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> Bool {
        await gitService.currentBranch(in: state.localPath) == branch
    }

    nonisolated private static func shouldSkipMergeDefaultBranch(
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> Bool {
        guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
            return false
        }
        return await isCurrentBranch(defaultBranch, for: state, gitService: gitService)
    }
}
