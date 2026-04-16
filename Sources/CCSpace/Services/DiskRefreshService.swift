import Foundation

struct DiskRefreshStoreSnapshot: Equatable, Sendable {
    let workplace: WorkplaceStoreSnapshot
    let repositories: [RepositoryConfig]
}

struct DiskRefreshComputationResult: Sendable {
    let workplaceResult: WorkplaceDiskRefreshResult
    let repositoryResult: RepositoryDeduplicationResult
}

@MainActor
struct DiskRefreshService {
    typealias RefreshCalculator = @Sendable (DiskRefreshStoreSnapshot, String) async -> DiskRefreshComputationResult

    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    private let refreshCalculator: RefreshCalculator

    init(
        workplaceStore: WorkplaceStore,
        repositoryStore: RepositoryStore,
        refreshCalculator: @escaping RefreshCalculator = DiskRefreshService.defaultRefreshCalculator
    ) {
        self.workplaceStore = workplaceStore
        self.repositoryStore = repositoryStore
        self.refreshCalculator = refreshCalculator
    }

    func refresh(rootPath: String) async {
        while Task.isCancelled == false {
            let snapshot = currentSnapshot()
            let refreshResults = await refreshCalculator(snapshot, rootPath)
            guard Task.isCancelled == false else { return }
            guard snapshot == currentSnapshot() else { continue }

            workplaceStore.applyDiskRefreshResult(refreshResults.workplaceResult)
            repositoryStore.applyDeduplicationResult(refreshResults.repositoryResult)
            return
        }
    }

    private func currentSnapshot() -> DiskRefreshStoreSnapshot {
        DiskRefreshStoreSnapshot(
            workplace: WorkplaceStore.snapshot(
                workplaces: workplaceStore.workplaces,
                syncStates: workplaceStore.syncStates
            ),
            repositories: repositoryStore.repositories
        )
    }

    nonisolated private static func defaultRefreshCalculator(
        snapshot: DiskRefreshStoreSnapshot,
        rootPath: String
    ) async -> DiskRefreshComputationResult {
        await Task.detached(priority: .utility) {
            DiskRefreshComputationResult(
                workplaceResult: WorkplaceStore.diskRefreshResult(
                    workplaces: snapshot.workplace.workplaces,
                    syncStates: snapshot.workplace.syncStates,
                    rootPath: rootPath
                ),
                repositoryResult: RepositoryStore.deduplicationResult(for: snapshot.repositories)
            )
        }.value
    }
}
