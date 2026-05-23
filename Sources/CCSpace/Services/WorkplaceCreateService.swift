import Foundation

@MainActor
struct WorkplaceCreateService {
    let repositoryStore: RepositoryStore
    let workplaceStore: WorkplaceStore
    let syncCoordinator: SyncCoordinator

    func createWorkplace(
        name: String,
        rootPath: String,
        selectedRepositoryIDs: [UUID],
        branch: String?,
        progressHandler: WorkplaceOperationProgressHandler? = nil
    ) async throws -> Workplace {
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = trimmedBranch?.isEmpty == true ? nil : trimmedBranch
        let selectedRepositories = repositoryStore.repositories.filter {
            selectedRepositoryIDs.contains($0.id)
        }

        let workplace = try workplaceStore.createWorkplace(
            name: name,
            rootPath: rootPath,
            selectedRepositories: selectedRepositories,
            branch: normalizedBranch
        )

        let directoryExistedBefore = FileManager.default.fileExists(atPath: workplace.path)

        do {
            let states = try await syncCoordinator.cloneRepositories(
                repositories: selectedRepositories,
                workplace: workplace,
                progressHandler: progressHandler
            )
            try workplaceStore.replaceSyncStates(states, for: workplace.id)
            return workplace
        } catch {
            try? workplaceStore.deleteWorkplace(workplace.id)
            if !directoryExistedBefore {
                try? syncCoordinator.fileSystemService.removeItemIfExists(at: workplace.path)
            }
            throw error
        }
    }
}
