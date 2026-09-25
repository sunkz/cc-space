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
                    let localPath: String
                    do {
                        localPath = try WorkplaceStore.repositoryPath(
                            workplacePath: workplacePath,
                            repositoryName: repositoryName
                        )
                    } catch {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        throw error
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
        do {
            try workplaceStore.updateSyncStates(preparation.failed + pullingStates)
        } catch {
            syncCoordinatorLog.error("event=update_pulling_states_failed reason=\(error.localizedDescription)")
        }

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
        do {
            try workplaceStore.updateSyncStates(resultStates)
        } catch {
            syncCoordinatorLog.error("event=update_result_states_failed reason=\(error.localizedDescription)")
        }

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
