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
    static let maxConcurrentCloneTasks = 4

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
        workplace: Workplace
    ) async throws -> [RepositorySyncState] {
        try fileSystemService.createDirectory(at: workplace.path)

        let gitService = gitService
        let workplaceID = workplace.id
        let workplacePath = workplace.path
        let workplaceBranch = workplace.branch
        return try await withThrowingTaskGroup(of: RepositorySyncState.self) { group in
            let initialTaskCount = min(Self.maxConcurrentCloneTasks, repositories.count)
            var nextRepositoryIndex = 0

            func addTask(for repository: RepositoryConfig) {
                let repositoryID = repository.id
                let repositoryURL = repository.gitURL
                let repositoryName = repository.repoName

                group.addTask {
                    try Task.checkCancellation()
                    let localPath = try WorkplaceStore.repositoryPath(
                        workplacePath: workplacePath,
                        repositoryName: repositoryName
                    )
                    do {
                        try await gitService.clone(repositoryURL: repositoryURL, into: localPath)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: localPath,
                            lastError: error.localizedDescription,
                            lastSyncedAt: nil
                        )
                    }

                    var checkoutError: String?
                    if let branch = workplaceBranch, !branch.isEmpty {
                        do {
                            try await gitService.checkoutBranch(branch, in: localPath)
                        } catch {
                            checkoutError = error.localizedDescription
                        }
                    }

                    return RepositorySyncState(
                        workplaceID: workplaceID,
                        repositoryID: repositoryID,
                        status: checkoutError != nil ? .failed : .success,
                        localPath: localPath,
                        lastError: checkoutError,
                        lastSyncedAt: .now
                    )
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
        await withTaskGroup(of: RepositorySyncState.self) { group in
            for state in preparation.pullable {
                let localPath = state.localPath
                group.addTask {
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
            }

            for await resultState in group {
                if resultState.status == .success {
                    successCount += 1
                } else if resultState.status == .failed {
                    failedCount += 1
                }
                resultStates.append(resultState)
            }
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

        return await withTaskGroup(
            of: PullPreparationDecision.self,
            returning: PullPreparationResult.self
        ) { group in
            for state in candidates {
                group.addTask {
                    guard let currentBranch = await gitService.currentBranch(in: state.localPath) else {
                        return .failed(
                            failedPullInspectionState(
                                state,
                                message: "无法识别当前分支"
                            )
                        )
                    }
                    guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
                        return .failed(
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
                        return .pullable(pullableState)
                    }

                    return .skipped
                }
            }

            var pullableStates: [RepositorySyncState] = []
            var normalizedStates: [RepositorySyncState] = []
            var failedStates: [RepositorySyncState] = []
            var skippedCount = 0
            for await result in group {
                switch result {
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
    }

    @MainActor
    func isGitAvailable() async -> Bool {
        await gitService.isGitAvailable()
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
