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

    func test_loadLegacyWorkplaceJSONDefaultsPinnedAndArchivedFlagsToFalse() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let legacyJSON = """
        [
          {
            "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "name": "legacy",
            "path": "/tmp/legacy",
            "selectedRepositoryIDs": ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"],
            "branch": "feature/legacy",
            "createdAt": "1970-01-01T00:00:00Z",
            "updatedAt": "1970-01-01T00:00:00Z"
          }
        ]
        """
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try legacyJSON.write(
            to: root.appendingPathComponent("workplaces.json"),
            atomically: true,
            encoding: .utf8
        )
        try "[]".write(
            to: root.appendingPathComponent("sync-states.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkplaceStore(fileStore: fileStore)

        let workplace = try XCTUnwrap(store.workplaces.first)
        XCTAssertFalse(workplace.isPinned)
        XCTAssertFalse(workplace.isArchived)
    }

    func test_setPinnedPersistsPinnedFlagAndUpdatedAt() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )

        try store.setPinned(true, for: workplace.id)

        let updatedWorkplace = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertTrue(updatedWorkplace.isPinned)
        XCTAssertGreaterThan(updatedWorkplace.updatedAt, workplace.updatedAt)

        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertTrue(reloadedStore.workplaces.first(where: { $0.id == workplace.id })?.isPinned == true)
    }

    func test_setArchivedPersistsArchivedFlagAndKeepsSelectedRepositories() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )

        try store.setArchived(true, for: workplace.id)

        let updatedWorkplace = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertTrue(updatedWorkplace.isArchived)
        XCTAssertEqual(updatedWorkplace.selectedRepositoryIDs, [repository.id])
        XCTAssertGreaterThan(updatedWorkplace.updatedAt, workplace.updatedAt)

        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        let persistedWorkplace = try XCTUnwrap(reloadedStore.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertTrue(persistedWorkplace.isArchived)
        XCTAssertEqual(persistedWorkplace.selectedRepositoryIDs, [repository.id])
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
            selectedRepositoryIDs: [secondRepository.id],
            repositories: []
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
            selectedRepositoryIDs: [firstRepository.id],
            repositories: []
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
        store.updateSyncState(updatedState)

        let result = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        XCTAssertEqual(result?.status, .success)
        XCTAssertEqual(result?.lastSyncedAt, Date(timeIntervalSince1970: 1000))
    }

    /// 行在 await 窗口内被整体替换掉(如 prune/去重)后,单行更新必须补录,
    /// 而不是静默丢弃(与 updateSyncStates 的补录语义一致)。
    func test_updateSyncStateBackfillsRowWhenWorkplaceStillExists() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )
        let existing = try XCTUnwrap(store.syncStates.first { $0.repositoryID == repository.id })

        store.replaceSyncStates([], for: workplace.id)
        XCTAssertTrue(store.syncStates.isEmpty)

        var arrived = existing
        arrived.status = .success
        store.updateSyncState(arrived)

        let restored = store.syncStates.first { $0.repositoryID == repository.id }
        XCTAssertEqual(restored?.status, .success)
        XCTAssertEqual(restored?.workplaceID, workplace.id)
    }

    /// 工作区记录已不存在时,单行更新不补录孤儿行(无 UI 入口,只会在 JSON 里累积)。
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
        store.updateSyncState(orphanState)

        XCTAssertEqual(store.syncStates.count, 1)
    }

    /// 批量更新遇到"状态行已被删掉"的未知 key 时必须补录,而不是静默跳过:
    /// 克隆完成走增量更新,若期间该仓库的行被去重/prune 掉,静默跳过会让克隆结果
    /// 永不落库,UI 上该仓库再也没有状态行。
    func test_updateSyncStatesAppendsMissingRowForSelectedRepository() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )
        let existing = try XCTUnwrap(store.syncStates.first { $0.repositoryID == repository.id })

        // 模拟"await 期间该行被删":整体替换成不含该行的集合。
        store.replaceSyncStates([], for: workplace.id)
        XCTAssertTrue(store.syncStates.isEmpty)

        var arrived = existing
        arrived.status = .success
        arrived.hasLocalDirectory = true
        store.updateSyncStates([arrived])

        let persisted = try XCTUnwrap(store.syncStates.first { $0.repositoryID == repository.id })
        XCTAssertEqual(persisted.status, .success)
        XCTAssertTrue(persisted.hasLocalDirectory)

        // 补录必须真的进入待写队列:flush 后重新加载仍在这条记录
        // (updateSyncStates 走防抖写盘,不是同步落盘)。
        store.flushSyncStates()
        let reloaded = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.syncStates.first { $0.repositoryID == repository.id }?.hasLocalDirectory, true)
    }

    /// 补录只针对**仍在该工作区选中列表里**的仓库:已被移出选中范围的仓库不能被
    /// 迟到回写"复活",否则会展示一个用户已经取消选择的仓库状态。
    func test_updateSyncStatesIgnoresRowForDeselectedRepository() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let kept = makeRepository(repoName: "api")
        let dropped = makeRepository(repoName: "legacy")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [kept, dropped]
        )
        // 取消勾选 legacy:该仓库的状态行随之被移除(留下"行已不存在"的场景)。
        try store.updateRepositories(for: workplace.id, selectedRepositoryIDs: [kept.id], repositories: [kept, dropped])

        let orphanRow = RepositorySyncState(
            workplaceID: workplace.id,
            repositoryID: dropped.id,
            status: .success,
            localPath: workplace.path + "/legacy",
            lastError: nil,
            lastSyncedAt: nil
        )
        store.updateSyncStates([orphanRow])

        XCTAssertNil(store.syncStates.first { $0.repositoryID == dropped.id })
        XCTAssertEqual(store.syncStates.count, 1)   // 只剩仍被选中的 api 行
        XCTAssertEqual(store.syncStates.first?.repositoryID, kept.id)
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

        store.setSyncStatus(.removing, for: workplace.id, repositoryIDs: [repo1.id])

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

        store.applyDiskRefreshResult(
            WorkplaceStore.diskRefreshResult(
                workplaces: store.workplaces,
                syncStates: store.syncStates,
                rootPath: root.path
            )
        )

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
        store.updateSyncState(state)

        store.applyDiskRefreshResult(
            WorkplaceStore.diskRefreshResult(
                workplaces: store.workplaces,
                syncStates: store.syncStates,
                rootPath: root.path
            )
        )

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

    func test_workplaceLegacyJSONDecodesPinnedRepositoryIDsAsEmpty() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "ios-dev",
            "path": "/tmp/ios-dev",
            "selectedRepositoryIDs": ["22222222-2222-2222-2222-222222222222"],
            "isPinned": false,
            "isArchived": false,
            "createdAt": 700000000.0,
            "updatedAt": 700000000.0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let workplace = try decoder.decode(Workplace.self, from: legacyJSON)

        XCTAssertEqual(workplace.pinnedRepositoryIDs, [])
    }

    func test_workplaceEncodesAndDecodesPinnedRepositoryIDsRoundTrip() throws {
        let repoID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let original = Workplace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "ios-dev",
            path: "/tmp/ios-dev",
            selectedRepositoryIDs: [repoID],
            pinnedRepositoryIDs: [repoID],
            createdAt: Date(timeIntervalSinceReferenceDate: 700000000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 700000000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workplace.self, from: data)

        XCTAssertEqual(decoded.pinnedRepositoryIDs, [repoID])
    }

    func test_setRepositoryPinnedAddsAndPersistsRepositoryID() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )

        try store.setRepositoryPinned(true, repositoryID: repository.id, in: workplace.id)

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.pinnedRepositoryIDs, [repository.id])
        XCTAssertGreaterThan(updated.updatedAt, workplace.updatedAt)

        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        let reloaded = try XCTUnwrap(reloadedStore.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(reloaded.pinnedRepositoryIDs, [repository.id])
    }

    func test_setRepositoryPinnedFalseRemovesRepositoryID() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )

        try store.setRepositoryPinned(true, repositoryID: repository.id, in: workplace.id)
        try store.setRepositoryPinned(false, repositoryID: repository.id, in: workplace.id)

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.pinnedRepositoryIDs, [])
    }

    func test_setRepositoryPinnedIsIdempotent() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )

        try store.setRepositoryPinned(true, repositoryID: repository.id, in: workplace.id)
        let firstSnapshot = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))

        try store.setRepositoryPinned(true, repositoryID: repository.id, in: workplace.id)
        let secondSnapshot = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))

        XCTAssertEqual(firstSnapshot.updatedAt, secondSnapshot.updatedAt)
        XCTAssertEqual(secondSnapshot.pinnedRepositoryIDs, [repository.id])
    }

    func test_setRepositoryPinnedIgnoresUnknownRepositoryID() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )
        let unrelatedID = UUID()

        try store.setRepositoryPinned(true, repositoryID: unrelatedID, in: workplace.id)

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.pinnedRepositoryIDs, [])
    }

    func test_updateRepositoriesRemovesPinnedIDsThatAreNoLongerSelected() throws {
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
            selectedRepositories: [firstRepository, secondRepository]
        )

        try store.setRepositoryPinned(true, repositoryID: firstRepository.id, in: workplace.id)
        try store.setRepositoryPinned(true, repositoryID: secondRepository.id, in: workplace.id)

        try store.updateRepositories(
            for: workplace.id,
            selectedRepositoryIDs: [secondRepository.id],
            repositories: [firstRepository, secondRepository]
        )

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.pinnedRepositoryIDs, [secondRepository.id])
    }

    func test_applyWorkplaceEditRemovesPinnedIDsThatAreNoLongerSelected() throws {
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
            selectedRepositories: [firstRepository, secondRepository]
        )

        try store.setRepositoryPinned(true, repositoryID: firstRepository.id, in: workplace.id)
        try store.setRepositoryPinned(true, repositoryID: secondRepository.id, in: workplace.id)

        var edited = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        edited.selectedRepositoryIDs = [secondRepository.id]
        let newSyncStates = store.syncStates.filter {
            $0.workplaceID == workplace.id && $0.repositoryID == secondRepository.id
        }

        try store.applyWorkplaceEdit(edited, syncStates: newSyncStates)

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.pinnedRepositoryIDs, [secondRepository.id])
    }

    /// removeRepositoryAssociations 已删除(死代码),等价覆盖指向其替代品
    /// stateAfterRemovingRepositoryAssociations(RepositoryStore.removeRepository
    /// 原子提交流程使用的数据源)。
    func test_stateAfterRemovingRepositoryAssociationsAlsoRemovesPinnedIDs() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let removedRepository = makeRepository(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            repoName: "api"
        )
        let keptRepository = makeRepository(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [removedRepository, keptRepository]
        )
        try store.setRepositoryPinned(true, repositoryID: removedRepository.id, in: workplace.id)
        try store.setRepositoryPinned(true, repositoryID: keptRepository.id, in: workplace.id)

        let plan = try XCTUnwrap(
            store.stateAfterRemovingRepositoryAssociations(repositoryID: removedRepository.id)
        )

        let updated = try XCTUnwrap(plan.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.selectedRepositoryIDs, [keptRepository.id])
        XCTAssertEqual(updated.pinnedRepositoryIDs, [keptRepository.id])
        XCTAssertTrue(plan.syncStates.allSatisfy { $0.repositoryID != removedRepository.id })
    }

    /// 选中列表变空时工作区记录保留,仅移除对应 sync state。
    func test_stateAfterRemovingRepositoryAssociationsKeepsWorkplaceWhenSelectionBecomesEmpty() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        let plan = try XCTUnwrap(
            store.stateAfterRemovingRepositoryAssociations(repositoryID: repository.id)
        )

        let updated = try XCTUnwrap(plan.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.selectedRepositoryIDs, [])
        XCTAssertTrue(plan.syncStates.isEmpty)
    }

    func test_backfillMissingSyncStatesRestoresLostStatesAndPersists() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )

        // 模拟 sync-states.json 损坏被重置后与 workplaces 脱节。
        store.replaceSyncStates([], for: workplace.id)

        try store.backfillMissingSyncStates(repositories: [repository])

        let restored = try XCTUnwrap(store.syncStates.first)
        XCTAssertEqual(restored.workplaceID, workplace.id)
        XCTAssertEqual(restored.repositoryID, repository.id)
        XCTAssertEqual(restored.status, .idle)
        XCTAssertEqual(restored.localPath, workplace.path + "/api")

        // 补建结果落盘:重新加载的 Store 能读到该状态。
        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedStore.syncStates.count, 1)
    }

    func test_backfillMissingSyncStatesSkipsRepositoriesWithoutConfig() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [repository]
        )
        store.replaceSyncStates([], for: workplace.id)

        // 配置缺失的仓库跳过补建,不报错。
        try store.backfillMissingSyncStates(repositories: [])
        XCTAssertTrue(store.syncStates.isEmpty)
    }

    func test_pruneReferencesToRepositoriesRemovesOrphanReferences() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let keptRepository = makeRepository(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            repoName: "api"
        )
        let deletedRepository = makeRepository(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            repoName: "web"
        )
        let rootPath = tempRoot().path
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: rootPath,
            selectedRepositories: [keptRepository, deletedRepository]
        )
        try store.setRepositoryPinned(true, repositoryID: deletedRepository.id, in: workplace.id)

        try store.pruneReferencesToRepositories(validRepositoryIDs: [keptRepository.id])

        let updated = try XCTUnwrap(store.workplaces.first(where: { $0.id == workplace.id }))
        XCTAssertEqual(updated.selectedRepositoryIDs, [keptRepository.id])
        // 测试里只置顶了被删仓库,清理后置顶列表为空。
        XCTAssertEqual(updated.pinnedRepositoryIDs, [])
        XCTAssertTrue(store.syncStates.allSatisfy { $0.repositoryID == keptRepository.id })

        // 清理结果落盘:重新加载的 Store 无孤儿引用。
        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertTrue(reloadedStore.workplaces.first?.selectedRepositoryIDs.contains(deletedRepository.id) != true)
    }

    func test_pruneReferencesToRepositoriesIsNoOpWithoutOrphans() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )
        let before = workplace.updatedAt

        try store.pruneReferencesToRepositories(validRepositoryIDs: [repository.id])

        XCTAssertEqual(store.workplaces.first?.updatedAt, before)
    }

    /// workplaceID 已不在 workplaces 集合内的 sync state 是孤儿记录
    /// (仓库 id 合法也一样),prune 必须一并清理,否则会在 JSON 里永久累积。
    func test_pruneReferencesToRepositoriesRemovesSyncStatesOfUnknownWorkplace() throws {
        let root = tempRoot()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = makeRepository(repoName: "api")
        let workplace = try store.createWorkplace(
            name: "ios-dev",
            rootPath: tempRoot().path,
            selectedRepositories: [repository]
        )
        let keptStates = store.syncStates.filter { $0.workplaceID == workplace.id }
        let orphanState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: repository.id,
            status: .success,
            localPath: "/tmp/nowhere/api",
            lastError: nil,
            lastSyncedAt: nil
        )
        store.replaceSyncStates(keptStates + [orphanState], for: workplace.id)
        XCTAssertEqual(store.syncStates.count, 2)

        try store.pruneReferencesToRepositories(validRepositoryIDs: [repository.id])

        XCTAssertEqual(store.syncStates.map(\.id), keptStates.map(\.id))

        // 清理结果落盘:重新加载后孤儿记录不再存在。
        store.flushSyncStates()
        let reloadedStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedStore.syncStates.count, keptStates.count)
    }

    func test_diskRefreshResultDeduplicationAlsoRemovesPinnedIDs() {
        let workplaceID = UUID()
        let keptID = UUID()
        let duplicateID = UUID()
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let workplaceURL = rootURL.appendingPathComponent("ios-dev")
        try? FileManager.default.createDirectory(at: workplaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workplace = Workplace(
            id: workplaceID,
            name: "ios-dev",
            path: workplaceURL.path,
            selectedRepositoryIDs: [keptID, duplicateID],
            pinnedRepositoryIDs: [keptID, duplicateID],
            createdAt: .now,
            updatedAt: .now
        )
        let states: [RepositorySyncState] = [
            RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: keptID,
                status: .success,
                localPath: "\(workplaceURL.path)/api",
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: duplicateID,
                status: .success,
                localPath: "\(workplaceURL.path)/api",
                lastError: nil,
                lastSyncedAt: nil
            )
        ]

        let result = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace],
            syncStates: states,
            rootPath: rootURL.path
        )

        XCTAssertTrue(result.changed)
        let updated = try? XCTUnwrap(result.workplaces.first(where: { $0.id == workplaceID }))
        XCTAssertEqual(updated?.selectedRepositoryIDs, [keptID])
        XCTAssertEqual(updated?.pinnedRepositoryIDs, [keptID])
    }

    // MARK: - 工作区根目录迁移

    /// rebaseWorkplacePaths 已删除(死代码),等价覆盖指向其替代品 rebasePlan
    /// (SettingsStore.updateRootPath 原子提交流程使用的数据源)。
    /// 换根只改记录、不移动磁盘文件——目录要不要搬由用户决定,但记录必须跟着走,
    /// 否则磁盘刷新会认为这些工作区"目录已不存在"而把整库清掉。
    func test_rebasePlanMovesWorkplaceAndSyncStatesToNewRoot() throws {
        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: tempRoot()))
        let oldRoot = "/Users/demo/OldWorkplaces"
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: oldRoot,
            selectedRepositories: [makeRepository(repoName: "api")]
        )

        let plan = try XCTUnwrap(
            store.rebasePlan(fromRoot: oldRoot, toRoot: "/Users/demo/NewWorkplaces")
        )

        XCTAssertEqual(plan.rebasedCount, 1)
        XCTAssertEqual(plan.workplaces.first?.path, "/Users/demo/NewWorkplaces/ios-dev")
        XCTAssertEqual(plan.syncStates.first?.localPath, "/Users/demo/NewWorkplaces/ios-dev/api")
    }

    func test_rebasePlanLeavesWorkplacesOutsideOldRootUntouched() throws {
        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: tempRoot()))
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: "/Users/demo/OldWorkplaces",
            selectedRepositories: [makeRepository(repoName: "api")]
        )

        let plan = store.rebasePlan(fromRoot: "/Users/demo/Elsewhere", toRoot: "/Users/demo/NewWorkplaces")

        XCTAssertNil(plan, "没有需要迁移的工作区时返回 nil")
    }

    /// 嵌套选择新根(新根是旧根的子目录)时,已位于新根下的工作区保持原样,
    /// 不能被二次嵌套(如 /A/team/x 被搬成 /A/team/team/x),其余工作区搬入新根。
    func test_rebasePlanKeepsWorkplacesAlreadyUnderNestedNewRoot() throws {
        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: tempRoot()))
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: "/Users/demo/OldWorkplaces/team",
            selectedRepositories: [makeRepository(repoName: "api")]
        )
        _ = try store.createWorkplace(
            name: "web",
            rootPath: "/Users/demo/OldWorkplaces",
            selectedRepositories: [makeRepository(repoName: "web")]
        )

        let plan = try XCTUnwrap(
            store.rebasePlan(
                fromRoot: "/Users/demo/OldWorkplaces",
                toRoot: "/Users/demo/OldWorkplaces/team"
            )
        )

        XCTAssertEqual(plan.rebasedCount, 1)
        let iosDev = try XCTUnwrap(plan.workplaces.first { $0.name == "ios-dev" })
        XCTAssertEqual(iosDev.path, "/Users/demo/OldWorkplaces/team/ios-dev")
        XCTAssertEqual(
            plan.syncStates.first { $0.workplaceID == iosDev.id }?.localPath,
            "/Users/demo/OldWorkplaces/team/ios-dev/api",
            "已在新根下的工作区,其同步态同样保持原样"
        )
        let web = try XCTUnwrap(plan.workplaces.first { $0.name == "web" })
        XCTAssertEqual(web.path, "/Users/demo/OldWorkplaces/team/web")
        XCTAssertEqual(
            plan.syncStates.first { $0.workplaceID == web.id }?.localPath,
            "/Users/demo/OldWorkplaces/team/web/web"
        )
    }

    /// 换到父级目录(扩大根范围)时,工作区本来就都在新根下,应全部原地不动。
    func test_rebasePlanKeepsEverythingWhenNewRootIsAncestor() throws {
        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: tempRoot()))
        let currentRoot = "/Users/demo/Workplaces/team"
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: currentRoot,
            selectedRepositories: [makeRepository(repoName: "api")]
        )

        let plan = store.rebasePlan(fromRoot: currentRoot, toRoot: "/Users/demo/Workplaces")

        XCTAssertNil(plan, "扩大根范围时无需迁移")
    }

    func test_rebasePlanIsNoOpWhenRootIsUnchanged() throws {
        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: tempRoot()))
        let root = "/Users/demo/Workplaces"
        _ = try store.createWorkplace(
            name: "ios-dev",
            rootPath: root,
            selectedRepositories: [makeRepository(repoName: "api")]
        )
        let updatedAtBefore = try XCTUnwrap(store.workplaces.first).updatedAt

        let plan = store.rebasePlan(fromRoot: root, toRoot: root)

        XCTAssertNil(plan, "根目录未变化时返回 nil")
        XCTAssertEqual(store.workplaces.first?.updatedAt, updatedAtBefore)
    }

    // MARK: - 磁盘刷新的删除保护

    /// 换根目录后所有工作区都会"不在新根下",此时绝不能把它们当成已删除清掉。
    func test_diskRefreshResultKeepsAllWorkplacesWhenNoneMatchRoot() throws {
        let rootURL = tempRoot()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("unrelated-folder"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workplace = Workplace(
            id: UUID(),
            name: "ios-dev",
            path: "/Users/demo/SomewhereElse/ios-dev",
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )

        let result = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace],
            syncStates: [],
            rootPath: rootURL.path
        )

        XCTAssertEqual(result.workplaces.map(\.id), [workplace.id], "全部不匹配时应整体保留")
    }

    /// 单个工作区目录被手动删掉时,仍然要正常清理。
    func test_diskRefreshResultStillRemovesIndividuallyMissingWorkplace() throws {
        let rootURL = tempRoot()
        let keptURL = rootURL.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let keptID = UUID()
        let missingID = UUID()
        let workplaces = [
            Workplace(
                id: keptID,
                name: "kept",
                path: keptURL.path,
                selectedRepositoryIDs: [],
                createdAt: .now,
                updatedAt: .now
            ),
            Workplace(
                id: missingID,
                name: "gone",
                path: rootURL.appendingPathComponent("gone").path,
                selectedRepositoryIDs: [],
                createdAt: .now,
                updatedAt: .now
            )
        ]

        let result = WorkplaceStore.diskRefreshResult(
            workplaces: workplaces,
            syncStates: [],
            rootPath: rootURL.path
        )

        XCTAssertEqual(result.workplaces.map(\.id), [keptID])
        XCTAssertTrue(result.changed)
    }

    /// 解码失败时原文件必须被改名保全,否则下次保存会用空数据覆写导致原内容不可恢复。
    func test_corruptWorkplacesFileIsPreservedAsideAndResetInMemory() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-a-json".utf8).write(to: root.appendingPathComponent("workplaces.json"))

        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertTrue(store.workplaces.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(
            contents.contains { $0.hasPrefix("workplaces.json.corrupt-") },
            "损坏的 workplaces.json 应被改名为 .corrupt-<时间戳> 保全"
        )
        XCTAssertFalse(contents.contains("workplaces.json"), "原损坏文件应已被改名,不再留在原位")
    }

    // MARK: - 磁盘刷新对进行中长操作的豁免(P0 竞态回归锁)

    func test_diskRefreshResultSparesMissingWorkplaceWhosePathIsLocked() throws {
        let rootURL = tempRoot()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // 另一份工作区目录在盘上,避免触发"全缺失=根目录异常"的整体保护,
        // 精确验证豁免只在被豁免的那条生效。
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("other"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workplace = Workplace(
            id: UUID(),
            name: "creating",
            path: rootURL.appendingPathComponent("creating").path,
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )
        // "other" 必须同时有记录:只有一条缺失记录时 missing.count == 记录总数,
        // 会先命中"全缺失=根目录异常"的整体保护,测不到逐条豁免/清理的分支。
        let survivor = Workplace(
            id: UUID(),
            name: "other",
            path: rootURL.appendingPathComponent("other").path,
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )
        let lockedKeys: Set<String> = [LocalPathSafety.canonicalLockKey(for: workplace.path)]

        let result = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace, survivor],
            syncStates: [],
            rootPath: rootURL.path,
            lockedPathKeys: lockedKeys
        )
        XCTAssertEqual(result.workplaces.map(\.id), [workplace.id, survivor.id], "持锁路径的记录不得被本轮刷新删除")
        XCTAssertFalse(result.changed)

        let unguarded = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace, survivor],
            syncStates: [],
            rootPath: rootURL.path
        )
        XCTAssertEqual(unguarded.workplaces.map(\.id), [survivor.id], "对照组:不持锁时缺失记录仍会被清理")
    }

    func test_diskRefreshResultSparesTransientCloningRowFromMissingRewrite() throws {
        let rootURL = tempRoot()
        let workplaceURL = rootURL.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workplaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workplace = Workplace(
            id: UUID(),
            name: "ws",
            path: workplaceURL.path,
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )
        let cloningRow = RepositorySyncState(
            workplaceID: workplace.id,
            repositoryID: UUID(),
            status: .cloning,
            localPath: workplaceURL.appendingPathComponent("api").path,
            lastError: nil,
            lastSyncedAt: nil
        )

        let result = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace],
            syncStates: [cloningRow],
            rootPath: rootURL.path
        )
        XCTAssertEqual(result.syncStates.first?.status, .cloning, "瞬态 .cloning 行正在被活跃操作驱动,不得被改写成假失败")
        XCTAssertFalse(result.changed)

        let idleRow = RepositorySyncState(
            workplaceID: workplace.id,
            repositoryID: cloningRow.repositoryID,
            status: .idle,
            localPath: cloningRow.localPath
        )
        let unguarded = WorkplaceStore.diskRefreshResult(
            workplaces: [workplace],
            syncStates: [idleRow],
            rootPath: rootURL.path
        )
        XCTAssertEqual(unguarded.syncStates.first?.status, .failed, "对照组:.idle 的缺失行仍按缺失改写")
    }

    func test_applyWorkplaceEditThrowsWhenRecordMissing() throws {
        let fileStore = JSONFileStore(rootDirectory: tempRoot())
        let store = WorkplaceStore(fileStore: fileStore)
        let ghost = Workplace(
            id: UUID(),
            name: "ghost",
            path: "/Users/demo/Workplaces/ghost",
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )

        XCTAssertThrowsError(try store.applyWorkplaceEdit(ghost, syncStates: [])) { error in
            XCTAssertEqual(error as? WorkplaceStoreError, .workplaceNotFound)
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
