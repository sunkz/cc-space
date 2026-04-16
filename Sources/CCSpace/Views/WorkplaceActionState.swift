import Foundation

/// Derived action state for a single workplace.
/// `repositories` is expected to contain repositories relevant to the workplace,
/// and we defensively intersect with `workplace.selectedRepositoryIDs` so an
/// accidentally broader input does not leak unrelated failures into the UI.
struct WorkplaceActionState {
    let workplace: Workplace
    let failedRepositories: [RepositoryConfig]
    let activeRepositoryCount: Int
    let hasPullableRepositories: Bool
    let hasLocalRepositories: Bool
    let isBusy: Bool
    let canRetryFailedRepositories: Bool
    let canSyncAllRepositories: Bool
    let canOpenDirectory: Bool

    init(
        workplace: Workplace,
        repositories: [RepositoryConfig],
        syncStates: [RepositorySyncState]
    ) {
        self.workplace = workplace

        let selectedRepositoryIDs = Set(workplace.selectedRepositoryIDs)
        var hasLocal = false
        var activeCount = 0
        var failedIDs = Set<UUID>()

        for state in syncStates where state.workplaceID == workplace.id && selectedRepositoryIDs.contains(state.repositoryID) {
            if state.hasLocalDirectory { hasLocal = true }
            switch state.status {
            case .cloning, .pulling, .removing: activeCount += 1
            case .failed: failedIDs.insert(state.repositoryID)
            case .idle, .success: break
            }
        }

        hasLocalRepositories = hasLocal
        activeRepositoryCount = activeCount
        isBusy = activeCount > 0
        hasPullableRepositories = hasLocal

        let failedRepositoryIDs = failedIDs

        failedRepositories = repositories.filter {
            selectedRepositoryIDs.contains($0.id) && failedRepositoryIDs.contains($0.id)
        }
        canRetryFailedRepositories = !failedRepositories.isEmpty && !isBusy
        canSyncAllRepositories = hasPullableRepositories && !isBusy
        canOpenDirectory = workplace.hasLocalDirectory
    }
}
