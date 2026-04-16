import XCTest
@testable import CCSpace

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum GitStubBehavior {
    case success
    case fail
    case suspend
}

private final class FileSystemServiceSpy: FileSystemServicing, @unchecked Sendable {
    private(set) var createdPaths: [String] = []

    func createDirectory(at path: String) throws {
        createdPaths.append(path)
    }

    func removeItem(at path: String) throws {}
}

actor GitServiceRecorder {
    private(set) var pulledDirectories: [String] = []

    func recordPull(directory: String) {
        pulledDirectories.append(directory)
    }
}

actor CloneConcurrencyRecorder {
    private(set) var activeCount = 0
    private(set) var maxActiveCount = 0

    func begin() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

struct CloneConcurrencyGitServiceSpy: GitServicing {
    let recorder = CloneConcurrencyRecorder()

    func clone(repositoryURL: String, into directory: String) async throws {
        await recorder.begin()
        try await Task.sleep(nanoseconds: 50_000_000)
        await recorder.end()
    }

    func pull(in directory: String) async throws {}
    func push(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { "main" }
    func defaultBranch(in directory: String) async -> String? { "main" }
    func currentBranch(in directory: String) async -> String? { "main" }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? { nil }
    func branches(in directory: String) async -> [String] { [] }
    func remoteURL(in directory: String) async -> String? { nil }
    func checkoutBranch(_ branch: String, in directory: String) async throws {}
    func createLocalBranch(_ branch: String, in directory: String) async throws {}
    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }
    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome { .merged }
}

struct GitServiceStub: GitServicing {
    var behavior: GitStubBehavior = .success
    var defaultBranchResult: String? = "main"
    var currentBranchResult: String? = "main"
    var remoteURLResult: String? = "git@github.com:test/repo.git"
    let recorder = GitServiceRecorder()

    func clone(repositoryURL: String, into directory: String) async throws {
        switch behavior {
        case .success:
            return
        case .fail:
            throw StubError(message: "clone failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func pull(in directory: String) async throws {
        await recorder.recordPull(directory: directory)
        switch behavior {
        case .success:
            return
        case .fail:
            throw StubError(message: "pull failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func push(in directory: String) async throws {
        switch behavior {
        case .success:
            return
        case .fail:
            throw StubError(message: "push failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { defaultBranchResult }
    func defaultBranch(in directory: String) async -> String? { defaultBranchResult }
    func currentBranch(in directory: String) async -> String? { currentBranchResult }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        GitBranchStatusSnapshot(
            currentBranch: currentBranchResult,
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false,
            hasUnpushedCommits: false,
            isBehindRemote: false
        )
    }
    func branches(in directory: String) async -> [String] { ["main"] }
    func remoteURL(in directory: String) async -> String? { remoteURLResult }
    func checkoutBranch(_ branch: String, in directory: String) async throws {
        switch behavior {
        case .success:
            return
        case .fail:
            throw StubError(message: "checkout failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func createLocalBranch(_ branch: String, in directory: String) async throws {
        switch behavior {
        case .success:
            return
        case .fail:
            throw StubError(message: "create branch failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        switch behavior {
        case .success:
            return .merged
        case .fail:
            throw StubError(message: "merge failed for test")
        case .suspend:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .merged
        }
    }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    func test_marksRepositorySuccessAfterClone() async throws {
        let fileSystemSpy = FileSystemServiceSpy()
        let coordinator = SyncCoordinator(gitService: GitServiceStub(), fileSystemService: fileSystemSpy)
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let workplace = Workplace(
            id: UUID(),
            name: "ios-dev",
            path: "/tmp/ios-dev",
            selectedRepositoryIDs: [repository.id],
            createdAt: .now,
            updatedAt: .now
        )

        let states = try await coordinator.cloneRepositories(
            repositories: [repository],
            workplace: workplace
        )

        XCTAssertEqual(fileSystemSpy.createdPaths, [workplace.path])
        XCTAssertEqual(states.first?.status, .success)
    }

    func test_marksRepositoryFailedAndKeepsErrorMessageWhenCloneFails() async throws {
        let coordinator = SyncCoordinator(
            gitService: GitServiceStub(behavior: .fail),
            fileSystemService: FileSystemServiceSpy()
        )
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let workplace = Workplace(
            id: UUID(),
            name: "ios-dev",
            path: "/tmp/ios-dev",
            selectedRepositoryIDs: [repository.id],
            createdAt: .now,
            updatedAt: .now
        )

        let states = try await coordinator.cloneRepositories(
            repositories: [repository],
            workplace: workplace
        )

        XCTAssertEqual(states.first?.status, .failed)
        XCTAssertNotNil(states.first?.lastError)
        XCTAssertTrue(states.first?.lastError?.contains("clone failed for test") == true)
    }

    func test_cloneRepositoriesPropagatesCancellation() async {
        let coordinator = SyncCoordinator(
            gitService: GitServiceStub(behavior: .suspend),
            fileSystemService: FileSystemServiceSpy()
        )
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let workplace = Workplace(
            id: UUID(),
            name: "ios-dev",
            path: "/tmp/ios-dev",
            selectedRepositoryIDs: [repository.id],
            createdAt: .now,
            updatedAt: .now
        )

        let task = Task {
            try await coordinator.cloneRepositories(
                repositories: [repository],
                workplace: workplace
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func test_cloneRepositoriesLimitsConcurrentCloneTasks() async throws {
        let gitService = CloneConcurrencyGitServiceSpy()
        let coordinator = SyncCoordinator(
            gitService: gitService,
            fileSystemService: FileSystemServiceSpy()
        )
        let repositories = (0..<(SyncCoordinator.maxConcurrentCloneTasks + 3)).map { index in
            RepositoryConfig(
                id: UUID(),
                gitURL: "git@github.com:org/repo-\(index).git",
                repoName: "repo-\(index)",
                createdAt: .now,
                updatedAt: .now
            )
        }
        let workplace = Workplace(
            id: UUID(),
            name: "ios-dev",
            path: tempWorkplaceRoot().appendingPathComponent("ios-dev").path,
            selectedRepositoryIDs: repositories.map(\.id),
            createdAt: .now,
            updatedAt: .now
        )

        _ = try await coordinator.cloneRepositories(
            repositories: repositories,
            workplace: workplace
        )

        let maxActiveCount = await gitService.recorder.maxActiveCount
        XCTAssertLessThanOrEqual(maxActiveCount, SyncCoordinator.maxConcurrentCloneTasks)
    }

    func test_pullUpdatesStatusToSuccessAndSetsLastSyncedAt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/api.git",
            repoName: "api", createdAt: .now, updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "pull-test",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        var clonedState = store.syncStates.first { $0.workplaceID == workplace.id }!
        clonedState.status = .success
        clonedState.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: clonedState.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(clonedState)

        let coordinator = SyncCoordinator(
            gitService: GitServiceStub(behavior: .success),
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        XCTAssertEqual(syncResult?.status, .success)
        XCTAssertNotNil(syncResult?.lastSyncedAt)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 1, failedCount: 0, skippedCount: 0)
        )
    }

    func test_pullSetsFailedStatusWithErrorOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/api.git",
            repoName: "api", createdAt: .now, updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "pull-fail",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        var clonedState = store.syncStates.first { $0.workplaceID == workplace.id }!
        clonedState.status = .success
        clonedState.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: clonedState.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(clonedState)

        let coordinator = SyncCoordinator(
            gitService: GitServiceStub(behavior: .fail),
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        XCTAssertEqual(syncResult?.status, .failed)
        XCTAssertNotNil(syncResult?.lastError)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 0, failedCount: 1, skippedCount: 0)
        )
    }

    func test_pullMarksRepositoryFailedWhenCurrentBranchCannotBeResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/api.git",
            repoName: "api", createdAt: .now, updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "pull-branch-missing",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        var clonedState = store.syncStates.first { $0.workplaceID == workplace.id }!
        clonedState.status = .success
        clonedState.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: clonedState.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(clonedState)

        let gitService = GitServiceStub(
            behavior: .success,
            defaultBranchResult: "main",
            currentBranchResult: nil,
            remoteURLResult: "git@github.com:org/api.git"
        )
        let coordinator = SyncCoordinator(
            gitService: gitService,
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        let pulledDirectories = await gitService.recorder.pulledDirectories

        XCTAssertEqual(syncResult?.status, .failed)
        XCTAssertEqual(syncResult?.lastError, "无法识别当前分支")
        XCTAssertTrue(pulledDirectories.isEmpty)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 0, failedCount: 1, skippedCount: 0)
        )
    }

    func test_pullMarksRepositoryFailedWhenDefaultBranchCannotBeResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/api.git",
            repoName: "api", createdAt: .now, updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "pull-default-branch-missing",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        var clonedState = store.syncStates.first { $0.workplaceID == workplace.id }!
        clonedState.status = .success
        clonedState.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: clonedState.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(clonedState)

        let gitService = GitServiceStub(
            behavior: .success,
            defaultBranchResult: nil,
            currentBranchResult: "main",
            remoteURLResult: "git@github.com:org/api.git"
        )
        let coordinator = SyncCoordinator(
            gitService: gitService,
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        let pulledDirectories = await gitService.recorder.pulledDirectories

        XCTAssertEqual(syncResult?.status, .failed)
        XCTAssertEqual(syncResult?.lastError, "无法识别仓库默认分支")
        XCTAssertTrue(pulledDirectories.isEmpty)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 0, failedCount: 1, skippedCount: 0)
        )
    }

    func test_pullSkipsNonSuccessRepositories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repo1 = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/api.git",
            repoName: "api", createdAt: .now, updatedAt: .now
        )
        let repo2 = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/web.git",
            repoName: "web", createdAt: .now, updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "skip-test",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repo1, repo2]
        )

        // repo1 stays .idle (should be skipped), repo2 is .success (should be pulled)
        var state2 = store.syncStates.first { $0.repositoryID == repo2.id }!
        state2.status = .success
        state2.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("web").path
        try FileManager.default.createDirectory(
            atPath: state2.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(state2)

        let coordinator = SyncCoordinator(
            gitService: GitServiceStub(behavior: .success),
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let result1 = store.syncStates.first { $0.repositoryID == repo1.id }
        let result2 = store.syncStates.first { $0.repositoryID == repo2.id }
        XCTAssertEqual(result1?.status, .idle, "idle repo should not be touched")
        XCTAssertEqual(result2?.status, .success, "success repo should be pulled")
        XCTAssertNotNil(result2?.lastSyncedAt)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 1, failedCount: 0, skippedCount: 0)
        )
    }

    func test_pullSkipsSuccessRepositoryWhenCurrentBranchIsNotDefaultBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "branch-filter",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        var state = store.syncStates.first { $0.workplaceID == workplace.id }!
        state.status = .success
        state.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        state.lastSyncedAt = nil
        try FileManager.default.createDirectory(
            atPath: state.localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try store.updateSyncState(state)

        let gitService = GitServiceStub(
            behavior: .success,
            defaultBranchResult: "main",
            currentBranchResult: "feature/test",
            remoteURLResult: "git@github.com:org/api.git"
        )
        let coordinator = SyncCoordinator(
            gitService: gitService,
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        let pulledDirectories = await gitService.recorder.pulledDirectories

        XCTAssertEqual(syncResult?.status, .success)
        XCTAssertNil(syncResult?.lastSyncedAt, "非默认分支不应触发刷新")
        XCTAssertTrue(pulledDirectories.isEmpty, "非默认分支仓库不应执行 git pull")
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 1)
        )
    }

    func test_pullPreservesFailedRepositoryWhenCurrentBranchIsNotDefaultBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        let workplace = try store.createWorkplace(
            name: "stale-failure",
            rootPath: root.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: root.path)
            .appendingPathComponent("stale-failure")
            .appendingPathComponent("api")
            .path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = store.syncStates.first { $0.workplaceID == workplace.id }!
        state.status = .failed
        state.localPath = localPath
        state.lastError = "There is no tracking information for the current branch."
        try store.updateSyncState(state)

        let gitService = GitServiceStub(
            behavior: .success,
            defaultBranchResult: "main",
            currentBranchResult: "feature/test",
            remoteURLResult: "git@github.com:org/api.git"
        )
        let coordinator = SyncCoordinator(
            gitService: gitService,
            fileSystemService: FileSystemServiceSpy()
        )

        let pullResult = await coordinator.pullRepositories(
            syncStates: store.syncStates.filter { $0.workplaceID == workplace.id },
            workplaceStore: store
        )

        let syncResult = store.syncStates.first { $0.workplaceID == workplace.id && $0.repositoryID == repository.id }
        let pulledDirectories = await gitService.recorder.pulledDirectories

        XCTAssertEqual(syncResult?.status, .failed)
        XCTAssertEqual(syncResult?.lastError, "There is no tracking information for the current branch.")
        XCTAssertTrue(pulledDirectories.isEmpty)
        XCTAssertEqual(
            pullResult,
            RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 1)
        )
    }

    func test_replaceSyncStatesReplacesTargetWorkplaceOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)

        let targetRepo = RepositoryConfig(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            gitURL: "git@github.com:org/target.git",
            repoName: "target",
            createdAt: .now,
            updatedAt: .now
        )
        let otherRepo = RepositoryConfig(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            gitURL: "git@github.com:org/other.git",
            repoName: "other",
            createdAt: .now,
            updatedAt: .now
        )
        let targetWorkplace = try store.createWorkplace(
            name: "target-wp",
            rootPath: workspaceRoot.path,
            selectedRepositories: [targetRepo]
        )
        let otherWorkplace = try store.createWorkplace(
            name: "other-wp",
            rootPath: workspaceRoot.path,
            selectedRepositories: [otherRepo]
        )

        let replacement = RepositorySyncState(
            workplaceID: targetWorkplace.id,
            repositoryID: targetRepo.id,
            status: .success,
            localPath: URL(fileURLWithPath: targetWorkplace.path).appendingPathComponent("target").path,
            lastError: nil,
            lastSyncedAt: .now
        )
        try store.replaceSyncStates([replacement], for: targetWorkplace.id)

        let targetState = store.syncStates.first {
            $0.workplaceID == targetWorkplace.id && $0.repositoryID == targetRepo.id
        }
        let otherState = store.syncStates.first {
            $0.workplaceID == otherWorkplace.id && $0.repositoryID == otherRepo.id
        }

        XCTAssertEqual(targetState?.status, .success)
        XCTAssertEqual(otherState?.status, .idle)
        XCTAssertEqual(store.syncStates.count, 2)
    }
}

private func tempWorkplaceRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
