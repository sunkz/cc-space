import XCTest
@testable import CCSpace

@MainActor
final class DiskRefreshServiceTests: XCTestCase {
    func test_refreshCleansMissingWorkplacesAndDeduplicatesRepositories() async throws {
        let appSupportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileStore = JSONFileStore(rootDirectory: appSupportRoot)
        let now = Date()

        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/blog.git",
            repoName: "blog",
            createdAt: now,
            updatedAt: now
        )
        let duplicateRepository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/blog.git",
            repoName: "blog",
            createdAt: now,
            updatedAt: now
        )
        try fileStore.save([repository, duplicateRepository], as: "repositories.json")

        let existingWorkplacePath = workspaceRoot.appendingPathComponent("existing").path
        let missingWorkplacePath = workspaceRoot.appendingPathComponent("missing").path
        try FileManager.default.createDirectory(
            atPath: existingWorkplacePath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: existingWorkplacePath).appendingPathComponent("blog").path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existingWorkplace = Workplace(
            id: UUID(),
            name: "existing",
            path: existingWorkplacePath,
            selectedRepositoryIDs: [repository.id],
            createdAt: now,
            updatedAt: now
        )
        let missingWorkplace = Workplace(
            id: UUID(),
            name: "missing",
            path: missingWorkplacePath,
            selectedRepositoryIDs: [repository.id],
            createdAt: now,
            updatedAt: now
        )
        try fileStore.save([existingWorkplace, missingWorkplace], as: "workplaces.json")

        let existingSyncState = RepositorySyncState(
            workplaceID: existingWorkplace.id,
            repositoryID: repository.id,
            status: .success,
            localPath: URL(fileURLWithPath: existingWorkplacePath).appendingPathComponent("blog").path,
            lastError: nil,
            lastSyncedAt: now
        )
        let missingSyncState = RepositorySyncState(
            workplaceID: missingWorkplace.id,
            repositoryID: repository.id,
            status: .failed,
            localPath: URL(fileURLWithPath: missingWorkplacePath).appendingPathComponent("blog").path,
            lastError: "missing",
            lastSyncedAt: nil
        )
        try fileStore.save([existingSyncState, missingSyncState], as: "sync-states.json")

        let repositoryStore = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        let service = DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore
        )

        await service.refresh(rootPath: workspaceRoot.path)

        XCTAssertEqual(repositoryStore.repositories.count, 1)
        XCTAssertEqual(repositoryStore.repositories.first?.id, repository.id)
        XCTAssertEqual(repositoryStore.repositories.first?.gitURL, repository.gitURL)
        XCTAssertEqual(repositoryStore.repositories.first?.repoName, repository.repoName)

        XCTAssertEqual(workplaceStore.workplaces.count, 1)
        XCTAssertEqual(workplaceStore.workplaces.first?.id, existingWorkplace.id)
        XCTAssertEqual(workplaceStore.workplaces.first?.name, existingWorkplace.name)
        XCTAssertEqual(workplaceStore.workplaces.first?.path, existingWorkplace.path)
        XCTAssertEqual(workplaceStore.workplaces.first?.selectedRepositoryIDs, existingWorkplace.selectedRepositoryIDs)

        XCTAssertEqual(workplaceStore.syncStates.count, 1)
        XCTAssertEqual(workplaceStore.syncStates.first?.workplaceID, existingSyncState.workplaceID)
        XCTAssertEqual(workplaceStore.syncStates.first?.repositoryID, existingSyncState.repositoryID)
        XCTAssertEqual(workplaceStore.syncStates.first?.status, existingSyncState.status)
        XCTAssertEqual(workplaceStore.syncStates.first?.localPath, existingSyncState.localPath)
        XCTAssertEqual(workplaceStore.syncStates.first?.lastError, existingSyncState.lastError)

        let reloadedRepositoryStore = RepositoryStore(fileStore: fileStore)
        let reloadedWorkplaceStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedRepositoryStore.repositories.count, 1)
        XCTAssertEqual(reloadedRepositoryStore.repositories.first?.id, repository.id)
        XCTAssertEqual(reloadedRepositoryStore.repositories.first?.gitURL, repository.gitURL)
        XCTAssertEqual(reloadedRepositoryStore.repositories.first?.repoName, repository.repoName)

        XCTAssertEqual(reloadedWorkplaceStore.workplaces.count, 1)
        XCTAssertEqual(reloadedWorkplaceStore.workplaces.first?.id, existingWorkplace.id)
        XCTAssertEqual(reloadedWorkplaceStore.workplaces.first?.name, existingWorkplace.name)
        XCTAssertEqual(reloadedWorkplaceStore.workplaces.first?.path, existingWorkplace.path)
        XCTAssertEqual(
            reloadedWorkplaceStore.workplaces.first?.selectedRepositoryIDs,
            existingWorkplace.selectedRepositoryIDs
        )

        XCTAssertEqual(reloadedWorkplaceStore.syncStates.count, 1)
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.first?.workplaceID, existingSyncState.workplaceID)
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.first?.repositoryID, existingSyncState.repositoryID)
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.first?.status, existingSyncState.status)
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.first?.localPath, existingSyncState.localPath)
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.first?.lastError, existingSyncState.lastError)
    }

    func test_refreshDoesNotApplyStaleSnapshotOverNewerSyncState() async throws {
        let appSupportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileStore = JSONFileStore(rootDirectory: appSupportRoot)
        let repositoryStore = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "existing",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )
        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var initialState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == repository.id
            }
        )
        initialState.status = .success
        initialState.lastSyncedAt = .now
        try workplaceStore.updateSyncState(initialState)

        let gate = RefreshGate()
        let calculationStarted = expectation(description: "refresh calculation started")
        calculationStarted.assertForOverFulfill = false
        let service = DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            refreshCalculator: { snapshot, rootPath in
                calculationStarted.fulfill()
                await gate.wait()
                return DiskRefreshComputationResult(
                    workplaceResult: WorkplaceStore.diskRefreshResult(
                        workplaces: snapshot.workplace.workplaces,
                        syncStates: snapshot.workplace.syncStates,
                        rootPath: rootPath
                    ),
                    repositoryResult: RepositoryStore.deduplicationResult(for: snapshot.repositories)
                )
            }
        )

        let refreshTask = Task {
            await service.refresh(rootPath: workspaceRoot.path)
        }

        await fulfillment(of: [calculationStarted], timeout: 1.0)

        var updatedState = initialState
        updatedState.status = .failed
        updatedState.lastError = "manual failure"
        updatedState.lastSyncedAt = nil
        try workplaceStore.updateSyncState(updatedState)

        await gate.release()
        await refreshTask.value

        let persistedState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == repository.id
            }
        )
        XCTAssertEqual(persistedState.status, .failed)
        XCTAssertEqual(persistedState.lastError, "manual failure")
        XCTAssertNil(persistedState.lastSyncedAt)
    }
}

private actor RefreshGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard released == false else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        guard released == false else { return }
        released = true
        let waiters = continuations
        continuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
