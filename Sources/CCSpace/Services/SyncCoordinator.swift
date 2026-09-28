import Foundation
import os

private let syncCoordinatorLog = Logger(
    subsystem: "com.ccspace.app",
    category: "SyncCoordinator"
)

struct RepositoryBranchPullOutcomeSummary: Sendable {
    let repositoryName: String
    let outcome: GitPullAllBranchesOutcome
}

struct RepositoryPullResult: Sendable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int
    let failedNames: [String]
    let branchSummaries: [RepositoryBranchPullOutcomeSummary]

    init(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int,
        failedNames: [String] = [],
        branchSummaries: [RepositoryBranchPullOutcomeSummary] = []
    ) {
        self.successCount = successCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.failedNames = failedNames
        self.branchSummaries = branchSummaries
    }

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

private struct PullPreparationResult {
    let pullable: [RepositorySyncState]
    let failed: [RepositorySyncState]
    let skippedCount: Int
}

private enum PullPreparationDecision {
    case pullable(RepositorySyncState)
    case failed(RepositorySyncState)
    case skipped
}

struct SyncCoordinator: Sendable {
    static let maxConcurrentCloneTasks = 2
    static let maxConcurrentPullTasks = 4

    let gitService: GitServicing
    let fileSystemService: FileSystemServicing

    init(
        gitService: GitServicing,
        fileSystemService: FileSystemServicing = FileSystemService()
    ) {
        self.gitService = gitService
        self.fileSystemService = fileSystemService
    }

    /// 批量克隆仓库并产出初始同步状态。
    ///
    /// 调用方必须已持有涉及路径的 RepositoryOperationLock(批量克隆约定);本方法不自行加锁
    /// (锁不支持重入,内部再加锁会与已持锁的调用方死锁)。
    ///
    /// `onCloneStarted`:某个仓库的克隆任务体**真正开始执行**时被回调登记目标路径。
    /// 编辑工作区的取消回滚只允许删除"已启动克隆"的目录:未启动的预期路径可能恰好
    /// 是用户既有同名目录,按预期清单误删会毁掉用户数据。
    @MainActor
    func cloneRepositories(
        repositories: [RepositoryConfig],
        workplace: Workplace,
        progressHandler: WorkplaceOperationProgressHandler? = nil,
        onCloneStarted: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [RepositorySyncState] {
        try fileSystemService.createDirectory(at: workplace.path)

        let gitService = gitService
        let workplaceID = workplace.id
        let workplacePath = workplace.path
        let workplaceBranch = workplace.branch
        let progressTracker = WorkplaceOperationProgressTracker(
            step: .cloningRepositories,
            totalCount: repositories.count,
            progressHandler: progressHandler
        )
        return try await withThrowingTaskGroup(of: RepositorySyncState.self) { group in
            let initialTaskCount = min(Self.maxConcurrentCloneTasks, repositories.count)
            var nextRepositoryIndex = 0

            func addTask(for repository: RepositoryConfig) {
                let repositoryID = repository.id
                let repositoryURL = repository.gitURL
                let repositoryName = repository.repoName

                group.addTask {
                    try Task.checkCancellation()
                    await progressTracker.didStart(repositoryName: repositoryName)
                    // 路径校验失败与 clone 失败同权:落为该仓库的 .failed 状态,
                    // 不让单个非法路径抛出任务组、作废整批已完成的克隆;只有取消可以冲出任务组。
                    let localPath: String
                    do {
                        localPath = try WorkplaceStore.repositoryPath(
                            workplacePath: workplacePath,
                            repositoryName: repositoryName
                        )
                    } catch is CancellationError {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        throw CancellationError()
                    } catch {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        return RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: "",
                            lastError: UserFacingError.message(for: error),
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                    }
                    let state: RepositorySyncState
                    // 走到这里说明该仓库的克隆真正开始执行(路径合法、未被取消),
                    // 登记为"已启动":只有这些目录允许被编辑回滚清理。
                    await onCloneStarted?(localPath)
                    do {
                        try await gitService.clone(repositoryURL: repositoryURL, into: localPath)
                    } catch is CancellationError {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        throw CancellationError()
                    } catch {
                        state = RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: localPath,
                            lastError: UserFacingError.message(for: error),
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        return state
                    }

                    var checkoutError: String?
                    if let branch = workplaceBranch, !branch.isEmpty {
                        do {
                            try await gitService.checkoutBranch(branch, in: localPath)
                        } catch {
                            checkoutError = UserFacingError.message(for: error)
                        }
                    }

                    state = RepositorySyncState(
                        workplaceID: workplaceID,
                        repositoryID: repositoryID,
                        status: checkoutError != nil ? .failed : .success,
                        localPath: localPath,
                        lastError: checkoutError,
                        lastSyncedAt: .now,
                        hasLocalDirectory: true
                    )
                    await progressTracker.didFinish(repositoryName: repositoryName)
                    return state
                }
            }

            for _ in 0..<initialTaskCount {
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }

            var states: [RepositorySyncState] = []
            while let state = try await group.next() {
                states.append(state)
                guard Task.isCancelled == false else {
                    group.cancelAll()
                    continue
                }
                guard nextRepositoryIndex < repositories.count else { continue }
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }
            return states
        }
    }

    @MainActor
    func pullRepositories(
        syncStates: [RepositorySyncState],
        workplaceStore: WorkplaceStore
    ) async -> RepositoryPullResult {
        let preparation = await Self.preparePullStates(
            from: syncStates,
            gitService: gitService
        )

        let pullingStates = preparation.pullable.map { state -> RepositorySyncState in
            var pullingState = state
            pullingState.status = .pulling
            pullingState.lastError = nil
            return pullingState
        }
        // 防抖持久化不抛错（见 WorkplaceStore.persistSyncStates），直接落库。
        workplaceStore.updateSyncStates(preparation.failed + pullingStates)

        let gitService = gitService
        let repoLock = RepositoryOperationLock.shared
        var successCount = 0
        var failedCount = preparation.failed.count
        let pulledResults = await Self.runLimitedTasks(
            preparation.pullable,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state -> (original: RepositorySyncState, result: RepositorySyncState, summary: RepositoryBranchPullOutcomeSummary?, cancelled: Bool) in
            let localPath = state.localPath
            let repositoryName = URL(fileURLWithPath: localPath).lastPathComponent
            // 与 push/切分支共用 per-path 锁,避免对同一仓库的跨类操作交错执行。
            do {
                let outcome = try await repoLock.withLock(path: localPath) {
                    try await gitService.pullAllBranches(in: localPath)
                }
                let summary = RepositoryBranchPullOutcomeSummary(repositoryName: repositoryName, outcome: outcome)
                if let primary = outcome.primaryError {
                    var failedState = state
                    failedState.status = .failed
                    failedState.lastError = UserFacingError.message(for: primary)
                    return (state, failedState, summary, false)
                }
                var successState = state
                successState.status = .success
                successState.lastSyncedAt = .now
                successState.lastError = nil
                return (state, successState, summary, false)
            } catch is CancellationError {
                // 取消不是失败:恢复操作前状态(pulling 只是副本状态,入参 state 未被改动),
                // 不把 "cancelled" 落库成 .failed,避免取消后 UI 出现整列假失败。
                // 标记 cancelled:该行进单独收口通道,不整行覆盖最新行(见下方回写)。
                return (state, state, nil, true)
            } catch {
                var failedState = state
                failedState.status = .failed
                failedState.lastError = UserFacingError.message(for: error)
                return (state, failedState, nil, false)
            }
        }
        let branchSummaries = pulledResults.compactMap(\.summary)

        var cancelledSnapshots: [RepositorySyncState] = []
        var results: [(original: RepositorySyncState, result: RepositorySyncState)] = []
        results.reserveCapacity(pulledResults.count)
        for entry in pulledResults {
            // 取消行不参与计数、不进结果:整行旧快照落库会把等锁期间磁盘刷新/其它
            // 操作写入最新行的字段覆盖回 pull 前(同类 lost update)。
            if entry.cancelled {
                cancelledSnapshots.append(entry.original)
                continue
            }
            if entry.result.status == .success {
                successCount += 1
            } else if entry.result.status == .failed {
                failedCount += 1
            }
            results.append((entry.original, entry.result))
        }
        // 回写按字段级增量合并(premarkedTransient: .pulling,见
        // RepositorySyncState.merging):pull 持锁可达数分钟,期间磁盘刷新/其他操作
        // 会改写行上与本操作无关的字段,整行覆盖会把取快照时的旧行落库,覆盖窗口内
        // 的最新写入(lost update)。只回写本操作改动的字段,并把本操作预标的
        // .pulling 瞬态归位为结果终态。
        var updates: [RepositorySyncState] = []
        updates.reserveCapacity(results.count)
        for entry in results {
            guard let current = workplaceStore.syncStates.first(where: {
                $0.workplaceID == entry.original.workplaceID && $0.repositoryID == entry.original.repositoryID
            }) else {
                // 行在 pull 窗口内被去重/prune:维持 updateSyncStates 的补录语义,
                // 原样回写结果行(仅仍被选中的行会真正落库,见 updateSyncStates)。
                updates.append(entry.result)
                continue
            }
            if let merged = RepositorySyncState.merging(
                updated: entry.result,
                onto: entry.original,
                in: current,
                premarkedTransient: .pulling
            ) {
                updates.append(merged)
            }
        }
        // 取消收口:只归位本批 pull 预标的 .pulling 瞬态(按字段增量合并到最新行,
        // 其余字段保留最新值);行上若是其它在途操作的瞬态则不动,由其自行收口。
        var cancelledRestores: [RepositorySyncState] = []
        for snapshot in cancelledSnapshots {
            guard let current = workplaceStore.syncStates.first(where: {
                $0.workplaceID == snapshot.workplaceID && $0.repositoryID == snapshot.repositoryID
            }) else { continue }
            guard current.status == .pulling else { continue }
            var restored = current
            restored.status = snapshot.status
            restored.lastError = snapshot.lastError
            cancelledRestores.append(restored)
        }
        workplaceStore.updateSyncStates(updates + cancelledRestores)

        // 失败名单须覆盖两段:准备阶段探测失败(branchStatus 不可读/目录异常,未进
        // pull 任务)与 pull 任务内失败的仓库,否则通知里只报后者、前者凭空消失。
        let failedNames = preparation.failed.map { URL(fileURLWithPath: $0.localPath).lastPathComponent }
            + results
                .filter { $0.result.status == .failed }
                .map { URL(fileURLWithPath: $0.result.localPath).lastPathComponent }

        return RepositoryPullResult(
            successCount: successCount,
            failedCount: failedCount,
            skippedCount: preparation.skippedCount,
            failedNames: failedNames,
            branchSummaries: branchSummaries
        )
    }

    private static func preparePullStates(
        from syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> PullPreparationResult {
        let candidates = syncStates.filter { state in
            state.localPath.isEmpty == false &&
            state.hasLocalDirectory &&
            state.status != .cloning &&
            state.status != .pulling &&
            state.status != .switching &&
            state.status != .removing
        }

        let decisions = await runLimitedTasks(
            candidates,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state in
            // branchStatus 探测在锁外执行,与后续加锁的 pull 之间存在 TOCTOU 窗口:
            // 探测结果可能过期(上游配置恰好变化)。可接受的取舍:探测只读且瞬时,
            // 若全程持锁会让每个仓库的检查串行排队,锁竞争代价远高于偶发的过期判断。
            guard let branchStatus = await gitService.branchStatus(in: state.localPath) else {
                return PullPreparationDecision.failed(
                    failedPullInspectionState(
                        state,
                        message: "无法读取仓库 Git 状态"
                    )
                )
            }
            guard branchStatus.hasRemoteTrackingBranch else {
                return PullPreparationDecision.skipped
            }
            // 不把 .failed 预翻成 .success 作"准备态":pull 被取消时下方循环会把
            // 该准备态原样返回并落库,造成"原失败仓库显示成功且行上残留旧 lastError"
            // 的自相矛盾(与下方"取消不落假失败"同一约定——取消时返回入参原始状态)。
            return PullPreparationDecision.pullable(state)
        }

        var pullableStates: [RepositorySyncState] = []
        var failedStates: [RepositorySyncState] = []
        var skippedCount = 0

        for decision in decisions {
            switch decision {
            case .pullable(let pullable):
                pullableStates.append(pullable)
            case .failed(let failed):
                failedStates.append(failed)
            case .skipped:
                skippedCount += 1
            }
        }

        return PullPreparationResult(
            pullable: pullableStates,
            failed: failedStates,
            skippedCount: skippedCount
        )
    }

    // MARK: - 独立窗口的仓库写操作(与后台 pull/push/切分支共用 per-path 锁)
    //
    // Diff / 提交记录窗口不经主工作区流程直接发起写操作;若不走锁,
    // 定时 pull 可在"git add 已执行、commit 未跑"的中间态插进来合并远端,
    // 或与 discard 交错产生 index.lock 冲突。这里统一收口到 RepositoryOperationLock。

    @MainActor
    func discardFileChanges(filePath: String, in directory: String) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.discardChanges(filePath: filePath, in: directory)
        }
    }

    @MainActor
    func commitAllChanges(message: String, in directory: String) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.commitAllChanges(message: message, in: directory)
        }
    }

    @MainActor
    func createBranchFromRevision(
        _ branch: String,
        fromRev rev: String,
        in directory: String
    ) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.createBranch(branch, fromRev: rev, in: directory)
        }
    }

    @MainActor
    func isGitAvailable() async -> Bool {
        await gitService.isGitAvailable()
    }

    private static func runLimitedTasks<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        await ConcurrencyUtilities.runLimitedTasks(
            inputs,
            maxConcurrentTasks: maxConcurrentTasks,
            operation: operation
        )
    }
}

private func failedPullInspectionState(
    _ state: RepositorySyncState,
    message: String
) -> RepositorySyncState {
    var failedState = state
    failedState.status = .failed
    failedState.lastError = message
    return failedState
}
