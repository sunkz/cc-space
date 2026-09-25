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

    /// 去重硬删除仓库后,必须立即清理工作区对它的引用(选中列表与 sync state),
    /// 不能等下次启动 prune——期间 UI 会展示指向已删仓库的悬空引用。
    func test_refreshPrunesWorkplaceReferencesAfterDeduplicationRemovesRepository() async throws {
        let appSupportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workplaceURL = workspaceRoot.appendingPathComponent("existing")
        try FileManager.default.createDirectory(
            at: workplaceURL.appendingPathComponent("blog"),
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
        // 与 repository 归一化后同 URL(尾部 ".git/" 差异),会被去重硬删除。
        let duplicateRepository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/blog.git/",
            repoName: "blog-copy",
            createdAt: now,
            updatedAt: now
        )
        try fileStore.save([repository, duplicateRepository], as: "repositories.json")

        let workplace = Workplace(
            id: UUID(),
            name: "existing",
            path: workplaceURL.path,
            selectedRepositoryIDs: [repository.id, duplicateRepository.id],
            createdAt: now,
            updatedAt: now
        )
        try fileStore.save([workplace], as: "workplaces.json")
        try fileStore.save(
            [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .success,
                    localPath: workplaceURL.appendingPathComponent("blog").path,
                    lastError: nil,
                    lastSyncedAt: now
                ),
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: duplicateRepository.id,
                    status: .idle,
                    localPath: workplaceURL.appendingPathComponent("blog-copy").path,
                    lastError: nil,
                    lastSyncedAt: nil
                ),
            ],
            as: "sync-states.json"
        )

        let repositoryStore = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        let service = DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore
        )

        await service.refresh(rootPath: workspaceRoot.path)

        XCTAssertEqual(repositoryStore.repositories.map(\.id), [repository.id])
        XCTAssertEqual(
            workplaceStore.workplaces.first?.selectedRepositoryIDs,
            [repository.id],
            "被去重删除仓库的选中引用应立即清理"
        )
        XCTAssertEqual(workplaceStore.syncStates.map(\.repositoryID), [repository.id])

        // 清理结果同批落盘。
        let reloadedWorkplaceStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedWorkplaceStore.workplaces.first?.selectedRepositoryIDs, [repository.id])
        XCTAssertEqual(reloadedWorkplaceStore.syncStates.map(\.repositoryID), [repository.id])
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

    func test_refreshRetriesUntilSnapshotStabilizesThenApplies() async throws {
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
        try repositoryStore.addRepository(gitURL: "git@github.com:org/app.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/lib.git")
        let repositories = repositoryStore.repositories
        XCTAssertEqual(repositories.count, 2)
        let workplace = try workplaceStore.createWorkplace(
            name: "retry-test",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories
        )
        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let presentRepo = try XCTUnwrap(repositories.first)
        let absentRepo = try XCTUnwrap(repositories.dropFirst(1).first)
        let presentState = try XCTUnwrap(
            workplaceStore.syncStates.first { $0.repositoryID == presentRepo.id }
        )
        // 仓库目录真实存在(默认 hasLocalDirectory 仍为 false,归一是刷新的职责),
        // absentRepo 的目录不存在,刷新后应保持 false——apply 是否发生以它俩为准。
        try FileManager.default.createDirectory(
            atPath: presentState.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let callCounter = CallCounter()
        let service = DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            refreshCalculator: { _, rootPath in
                let count = await callCounter.increment()
                // 只在第 1 次调用时做一处**真实**状态变更(目录存在但标记为 false
                // → 改成 true),让快照可见地变化。
                // 此前"每次调用都改"使刷新永远落在"持续变化→放弃"分支,
                // applyDiskRefreshResult 的落库路径完全失去覆盖。
                if count == 1 {
                    await MainActor.run {
                        guard var state = workplaceStore.syncStates
                            .first(where: { $0.repositoryID == presentRepo.id }) else { return }
                        state.hasLocalDirectory = true
                        try? workplaceStore.updateSyncState(state)
                    }
                }
                // 从当前库状态计算结果(第 1 次调用后库已被改动)。
                // 计算器是 @Sendable 闭包可能跑在非主线程,访问 MainActor 库须回主线程。
                return await MainActor.run {
                    DiskRefreshComputationResult(
                        workplaceResult: WorkplaceStore.diskRefreshResult(
                            workplaces: workplaceStore.workplaces,
                            syncStates: workplaceStore.syncStates,
                            rootPath: rootPath
                        ),
                        repositoryResult: RepositoryStore.deduplicationResult(for: repositoryStore.repositories)
                    )
                }
            }
        )

        await service.refresh(rootPath: workspaceRoot.path)

        let totalCalls = await callCounter.count
        // 第 1 次:计算器改动库状态→快照不一致→重试;第 2 次:快照稳定→apply。
        XCTAssertEqual(totalCalls, 2)
        // apply 必须真正落库:present 仓库归一为 true,absent 仓库保持 false。
        // 若 apply 路径回归(永远只重试),这里会停在 false。
        let persistedPresent = try XCTUnwrap(
            workplaceStore.syncStates.first { $0.repositoryID == presentRepo.id }
        )
        let persistedAbsent = try XCTUnwrap(
            workplaceStore.syncStates.first { $0.repositoryID == absentRepo.id }
        )
        XCTAssertTrue(persistedPresent.hasLocalDirectory)
        XCTAssertFalse(persistedAbsent.hasLocalDirectory)
    }
}

private actor CallCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
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
