import XCTest
@testable import CCSpace

@MainActor
final class WorkplaceStoreTests: XCTestCase {
    func test_createWorkplaceBuildsPathFromRootAndName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            repoName: "api"
        )

        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: "/Users/demo/Workplaces",
            selectedRepositories: [repository]
        )

        XCTAssertEqual(workplace.path, "/Users/demo/Workplaces/ios-dev")
        XCTAssertEqual(store.syncStates.first?.localPath, "/Users/demo/Workplaces/ios-dev/api")
    }

    func test_createWorkplaceRejectsMissingRootPath() {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)

        XCTAssertThrowsError(
            try store.createWorkplace(name: "ios-dev", rootPath: "", selectedRepositories: [makeRepository(repoName: "api")])
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .missingRootPath)
        }
    }

    func test_createWorkplaceRejectsEmptyName() {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot().path

        XCTAssertThrowsError(
            try store.createWorkplace(name: "   ", rootPath: rootPath, selectedRepositories: [makeRepository(repoName: "api")])
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .emptyName)
        }
    }

    func test_createWorkplaceRejectsInvalidName() {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot().path

        XCTAssertThrowsError(
            try store.createWorkplace(
                name: "../ios-dev",
                rootPath: rootPath,
                selectedRepositories: [makeRepository(repoName: "api")]
            )
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .invalidName)
        }
    }

    func test_createWorkplaceRejectsNoRepositories() {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot().path

        XCTAssertThrowsError(
            try store.createWorkplace(name: "ios-dev", rootPath: rootPath, selectedRepositories: [])
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .noRepositoriesSelected)
        }
    }

    func test_createWorkplaceRejectsDuplicatePath() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot().path

        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [makeRepository(repoName: "api")]
        )

        XCTAssertThrowsError(
            try store.createWorkplace(name: "ios-dev", rootPath: rootPath, selectedRepositories: [makeRepository(repoName: "web")])
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .duplicatePath)
        }
    }

    func test_createWorkplaceRejectsExistingDirectoryOnDisk() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot()
        try FileManager.default.createDirectory(
            at: rootPath.appendingPathComponent("ios-dev"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try store.createWorkplace(
                name: "ios-dev",
                rootPath: rootPath.path,
                selectedRepositories: [makeRepository(repoName: "api")]
            )
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .pathAlreadyExistsOnDisk)
        }
    }

    func test_createWorkplacePersistsWorkplacesAndSyncStates() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path

        let workplace = try firstStore.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        let secondStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(secondStore.workplaces.count, 1)
        XCTAssertEqual(secondStore.workplaces.first?.id, workplace.id)
        XCTAssertEqual(secondStore.syncStates.count, 1)
        XCTAssertEqual(secondStore.syncStates.first?.repositoryID, repository.id)
    }

    func test_updateRepositoriesUpdatesSelectedRepositoryIDs() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let firstRepository = makeRepository(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            repoName: "api"
        )
        let secondRepository = makeRepository(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [firstRepository]
        )

        try store.updateRepositories(
            for: workplace.id,
            selectedRepositoryIDs: [secondRepository.id]
        )

        XCTAssertEqual(store.workplaces.first?.selectedRepositoryIDs, [secondRepository.id])
    }

    func test_updateRepositoriesRemovesDeselectedSyncStatesAndPersists() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let firstRepository = makeRepository(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            repoName: "api"
        )
        let secondRepository = makeRepository(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [firstRepository, secondRepository]
        )

        try store.updateRepositories(
            for: workplace.id,
            selectedRepositoryIDs: [firstRepository.id]
        )

        let inMemoryStates = store.syncStates.filter { $0.workplaceID == workplace.id }
        XCTAssertEqual(inMemoryStates.map(\.repositoryID), [firstRepository.id])

        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        let persistedStates = reloadedStore.syncStates.filter { $0.workplaceID == workplace.id }
        XCTAssertEqual(persistedStates.map(\.repositoryID), [firstRepository.id])
    }

    func test_updateSyncStateReplacesMatchingState() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        var updatedState = store.syncStates.first!
        updatedState.status = .success
        updatedState.lastSyncedAt = Date(timeIntervalSince1970: 1000)
        try store.updateSyncState(updatedState)

        let result = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        XCTAssertEqual(result?.status, .success)
        XCTAssertEqual(result?.lastSyncedAt, Date(timeIntervalSince1970: 1000))
    }

    func test_updateSyncStateNoOpWhenNotFound() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        let orphanState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: "/tmp/nowhere",
            lastError: nil,
            lastSyncedAt: nil
        )
        try store.updateSyncState(orphanState)

        XCTAssertEqual(store.syncStates.count, 1)
    }

    func test_setSyncStatusUpdatesBulkStatus() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repo1 = makeRepository(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            repoName: "api"
        )
        let repo2 = makeRepository(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repo1, repo2]
        )

        try store.setSyncStatus(.removing, for: workplace.id, repositoryIDs: [repo1.id])

        let state1 = store.syncStates.first { $0.repositoryID == repo1.id }
        let state2 = store.syncStates.first { $0.repositoryID == repo2.id }
        XCTAssertEqual(state1?.status, .removing)
        XCTAssertEqual(state2?.status, .idle)
    }

    func test_applyWorkplaceEditReplacesWorkplaceAndSyncStatesTogether() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repo1 = makeRepository(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            repoName: "api"
        )
        let repo2 = makeRepository(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repo1]
        )

        var updatedWorkplace = workplace
        updatedWorkplace.name = "ios-prod"
        updatedWorkplace.path = URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod").path
        updatedWorkplace.selectedRepositoryIDs = [repo2.id]
        updatedWorkplace.branch = "release"
        updatedWorkplace.updatedAt = Date(timeIntervalSince1970: 2000)

        let updatedState = RepositorySyncState(
            workplaceID: workplace.id,
            repositoryID: repo2.id,
            status: .success,
            localPath: URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod/web").path,
            lastError: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 3000)
        )

        try store.applyWorkplaceEdit(updatedWorkplace, syncStates: [updatedState])

        let inMemoryWorkplace = store.workplaces.first { $0.id == workplace.id }
        XCTAssertEqual(inMemoryWorkplace?.name, "ios-prod")
        XCTAssertEqual(inMemoryWorkplace?.selectedRepositoryIDs, [repo2.id])
        XCTAssertEqual(inMemoryWorkplace?.branch, "release")
        XCTAssertEqual(store.syncStates.filter { $0.workplaceID == workplace.id }, [updatedState])

        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        let persistedWorkplace = reloadedStore.workplaces.first { $0.id == workplace.id }
        XCTAssertEqual(persistedWorkplace?.name, "ios-prod")
        XCTAssertEqual(persistedWorkplace?.selectedRepositoryIDs, [repo2.id])
        XCTAssertEqual(reloadedStore.syncStates.filter { $0.workplaceID == workplace.id }, [updatedState])
    }

    func test_refreshFromDiskDoesNotAutoImportUnknownWorkplaceOrRepository() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)

        let unknownWorkplacePath = root.appendingPathComponent("manual-workspace")
        let unknownRepoPath = unknownWorkplacePath.appendingPathComponent("manual-repo").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: unknownRepoPath).appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        store.refreshFromDisk(rootPath: root.path)

        XCTAssertTrue(store.workplaces.isEmpty)
        XCTAssertTrue(store.syncStates.isEmpty)
    }

    func test_refreshFromDiskMarksMissingKnownRepositoryStateFailedAndPreservesSelection() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: root.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true
        )

        var state = try XCTUnwrap(store.syncStates.first { $0.workplaceID == workplace.id })
        state.status = .success
        state.lastSyncedAt = .now
        try store.updateSyncState(state)

        store.refreshFromDisk(rootPath: root.path)

        let refreshedState = try XCTUnwrap(
            store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        )
        XCTAssertEqual(refreshedState.status, .failed)
        XCTAssertEqual(refreshedState.lastError, "仓库本地目录不存在")
        XCTAssertNil(refreshedState.lastSyncedAt)
        XCTAssertEqual(store.workplaces.count, 1)
        XCTAssertEqual(
            store.workplaces.first(where: { $0.id == workplace.id })?.selectedRepositoryIDs,
            [repository.id]
        )
    }

    func test_renameWorkplaceUpdatesNamePathAndSyncPaths() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        // Create the directory so moveItem succeeds
        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true
        )

        try store.renameWorkplace(id: workplace.id, newName: "ios-prod")

        let updated = store.workplaces.first { $0.id == workplace.id }
        XCTAssertEqual(updated?.name, "ios-prod")
        XCTAssertEqual(updated?.path, URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod").path)

        let syncState = store.syncStates.first { $0.workplaceID == workplace.id }
        XCTAssertEqual(
            syncState?.localPath,
            URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod/api").path
        )

        // Verify persistence
        let reloaded = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.workplaces.first?.name, "ios-prod")
        XCTAssertEqual(
            reloaded.syncStates.first?.localPath,
            URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod/api").path
        )

        // Cleanup
        try? FileManager.default.removeItem(
            atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("ios-prod").path
        )
    }

    func test_renameWorkplaceRejectsEmptyName() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        XCTAssertThrowsError(
            try store.renameWorkplace(id: workplace.id, newName: "   ")
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .emptyName)
        }
    }

    func test_renameWorkplaceRejectsInvalidName() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot()
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath.path,
            selectedRepositories: [repository]
        )

        XCTAssertThrowsError(
            try store.renameWorkplace(id: workplace.id, newName: "../ios-prod")
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .invalidName)
        }
    }

    func test_renameWorkplaceRejectsDuplicatePath() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repo1 = makeRepository(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            repoName: "api"
        )
        let repo2 = makeRepository(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repo1]
        )
        let second = try store.createWorkplace(
            name: "ios-staging",
            rootPath: rootPath,
            selectedRepositories: [repo2]
        )

        XCTAssertThrowsError(
            try store.renameWorkplace(id: second.id, newName: "ios-dev")
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .duplicatePath)
        }
    }

    func test_renameWorkplaceRejectsExistingDirectoryOnDisk() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let rootPath = tempRoot()
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootPath.appendingPathComponent("ios-prod"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try store.renameWorkplace(id: workplace.id, newName: "ios-prod")
        ) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .pathAlreadyExistsOnDisk)
        }
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeRepository(id: UUID = UUID(), repoName: String) -> RepositoryConfig {
        RepositoryConfig(
            id: id,
            gitURL: "git@github.com:org/\(repoName).git",
            repoName: repoName,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
