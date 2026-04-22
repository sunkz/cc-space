import Foundation

struct RepositoryPullResult: Equatable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

private struct PullPreparationResult {
    let pullable: [RepositorySyncState]
    let normalized: [RepositorySyncState]
    let failed: [RepositorySyncState]
    let skippedCount: Int
}

private enum PullPreparationDecision {
    case pullable(RepositorySyncState)
    case normalized(RepositorySyncState)
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
                            lastSyncedAt: nil
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
                        lastSyncedAt: .now
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
        try? workplaceStore.updateSyncStates(preparation.normalized + preparation.failed + pullingStates)

        let gitService = gitService
        var successCount = 0
        var failedCount = preparation.failed.count
        var resultStates = preparation.failed
        let pulledStates = await Self.runLimitedTasks(
            preparation.pullable,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state in
            let localPath = state.localPath
            do {
                try await gitService.pull(in: localPath)
                var successState = state
                successState.status = .success
                successState.lastSyncedAt = .now
                successState.lastError = nil
                return successState
            } catch {
                var failedState = state
                failedState.status = .failed
                failedState.lastError = error.localizedDescription
                return failedState
            }
        }

        for resultState in pulledStates {
            if resultState.status == .success {
                successCount += 1
            } else if resultState.status == .failed {
                failedCount += 1
            }
            resultStates.append(resultState)
        }
        try? workplaceStore.updateSyncStates(resultStates)

        return RepositoryPullResult(
            successCount: successCount,
            failedCount: failedCount,
            skippedCount: preparation.skippedCount
        )
    }

    private static func preparePullStates(
        from syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> PullPreparationResult {
        let candidates = syncStates.filter { state in
            state.localPath.isEmpty == false &&
            FileManager.default.fileExists(atPath: state.localPath) &&
            state.status != .cloning &&
            state.status != .pulling &&
            state.status != .removing
        }

        let decisions = await runLimitedTasks(
            candidates,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state in
            guard let currentBranch = await gitService.currentBranch(in: state.localPath) else {
                return PullPreparationDecision.failed(
                    failedPullInspectionState(
                        state,
                        message: "无法识别当前分支"
                    )
                )
            }
            guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
                return PullPreparationDecision.failed(
                    failedPullInspectionState(
                        state,
                        message: "无法识别仓库默认分支"
                    )
                )
            }

            if currentBranch == defaultBranch {
                var pullableState = state
                if pullableState.status == .failed {
                    pullableState.status = .success
                }
                return PullPreparationDecision.pullable(pullableState)
            }

            return PullPreparationDecision.skipped
        }

        var pullableStates: [RepositorySyncState] = []
        var normalizedStates: [RepositorySyncState] = []
        var failedStates: [RepositorySyncState] = []
        var skippedCount = 0

        for decision in decisions {
            switch decision {
            case .pullable(let pullable):
                pullableStates.append(pullable)
            case .normalized(let normalized):
                normalizedStates.append(normalized)
            case .failed(let failed):
                failedStates.append(failed)
            case .skipped:
                skippedCount += 1
            }
        }

        return PullPreparationResult(
            pullable: pullableStates,
            normalized: normalizedStates,
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
        guard inputs.isEmpty == false else { return [] }

        return await withTaskGroup(of: (Int, Output).self, returning: [Output].self) { group in
            let initialTaskCount = min(maxConcurrentTasks, inputs.count)
            var nextInputIndex = 0
            var results = Array<Output?>(repeating: nil, count: inputs.count)

            func addTask(for index: Int) {
                let input = inputs[index]
                group.addTask {
                    (index, await operation(input))
                }
            }

            for _ in 0..<initialTaskCount {
                addTask(for: nextInputIndex)
                nextInputIndex += 1
            }

            while let (index, result) = await group.next() {
                results[index] = result
                guard nextInputIndex < inputs.count else { continue }
                addTask(for: nextInputIndex)
                nextInputIndex += 1
            }

            return results.compactMap { $0 }
        }
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
