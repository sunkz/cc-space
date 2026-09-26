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
    @MainActor
    func cloneRepositories(
        repositories: [RepositoryConfig],
        workplace: Workplace,
        progressHandler: WorkplaceOperationProgressHandler? = nil
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
                            lastError: error.localizedDescription,
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                    }
                    let state: RepositorySyncState
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
                            lastError: error.localizedDescription,
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
                            checkoutError = error.localizedDescription
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
        var resultStates = preparation.failed
        let pulledResults = await Self.runLimitedTasks(
            preparation.pullable,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state -> (RepositorySyncState, RepositoryBranchPullOutcomeSummary?) in
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
                    failedState.lastError = primary.localizedDescription
                    return (failedState, summary)
                }
                var successState = state
                successState.status = .success
                successState.lastSyncedAt = .now
                successState.lastError = nil
                return (successState, summary)
            } catch is CancellationError {
                // 取消不是失败:恢复操作前状态(pulling 只是副本状态,入参 state 未被改动),
                // 不把 "cancelled" 落库成 .failed,避免取消后 UI 出现整列假失败。
                return (state, nil)
            } catch {
                var failedState = state
                failedState.status = .failed
                failedState.lastError = error.localizedDescription
                return (failedState, nil)
            }
        }
        let pulledStates = pulledResults.map(\.0)
        let branchSummaries = pulledResults.compactMap(\.1)

        for resultState in pulledStates {
            if resultState.status == .success {
                successCount += 1
            } else if resultState.status == .failed {
                failedCount += 1
            }
            resultStates.append(resultState)
        }
        workplaceStore.updateSyncStates(resultStates)

        let failedNames = resultStates
            .filter { $0.status == .failed }
            .map { URL(fileURLWithPath: $0.localPath).lastPathComponent }

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
            var pullableState = state
            if pullableState.status == .failed {
                pullableState.status = .success
            }
            return PullPreparationDecision.pullable(pullableState)
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
