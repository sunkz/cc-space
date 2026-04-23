import XCTest
@testable import CCSpace

private struct WorkplaceCreateStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor WorkplaceCreateGitServiceSpy: GitServicing {
    private(set) var cloneCalls: [(repositoryURL: String, directory: String)] = []
    private(set) var checkoutCalls: [(branch: String, directory: String)] = []

    func clone(repositoryURL: String, into directory: String) async throws {
        cloneCalls.append((repositoryURL: repositoryURL, directory: directory))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func pull(in directory: String) async throws {}
    func push(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { "main" }
    func defaultBranch(in directory: String) async -> String? { "main" }
    func currentBranch(in directory: String) async -> String? { "main" }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        GitBranchStatusSnapshot(
            currentBranch: "main",
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false,
            hasUnpushedCommits: false,
            isBehindRemote: false
        )
    }
    func branches(in directory: String) async -> [String] { ["main"] }
    func remoteURL(in directory: String) async -> String? { "git@github.com:test/repo.git" }

    func checkoutBranch(_ branch: String, in directory: String) async throws {
        checkoutCalls.append((branch: branch, directory: directory))
    }

    func createLocalBranch(_ branch: String, in directory: String) async throws {
        checkoutCalls.append((branch: branch, directory: directory))
    }

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        .merged
    }

    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }

    func cloneDirectories() async -> [String] {
        cloneCalls.map(\.directory)
    }

    func checkoutBranches() async -> [String] {
        checkoutCalls.map(\.branch)
    }
}

private final class FailingCreateWorkplaceDirectoryFileSystemService: FileSystemServicing {
    func createDirectory(at path: String) throws {
        throw WorkplaceCreateStubError(message: "create directory failed for test")
    }

    func removeItem(at path: String) throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }
}

@MainActor
final class WorkplaceCreateServiceTests: XCTestCase {
    func test_createWorkplaceCreatesAndClonesSelectedRepositories() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })

        let gitService = WorkplaceCreateGitServiceSpy()
        let service = WorkplaceCreateService(
            repositoryStore: repositoryStore,
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService)
        )

        let workplace = try await service.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositoryIDs: [apiRepository.id, webRepository.id],
            branch: "release"
        )

        XCTAssertEqual(workplace.name, "blog")
        XCTAssertEqual(workplace.branch, "release")
        XCTAssertEqual(workplace.selectedRepositoryIDs.count, 2)
        XCTAssertTrue(workplaceStore.workplaces.contains { $0.id == workplace.id })

        let syncStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }
        XCTAssertEqual(syncStates.count, 2)
        XCTAssertTrue(syncStates.allSatisfy { $0.status == .success })
        XCTAssertTrue(syncStates.allSatisfy { $0.lastError == nil })
        XCTAssertTrue(syncStates.allSatisfy { FileManager.default.fileExists(atPath: $0.localPath) })

        let cloneDirectories = await gitService.cloneDirectories().sorted()
        XCTAssertEqual(
            cloneDirectories,
            syncStates.map(\.localPath).sorted()
        )

        let checkoutBranches = await gitService.checkoutBranches().sorted()
        XCTAssertEqual(checkoutBranches, ["release", "release"])
    }

    func test_createWorkplaceReportsCloneProgress() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)

        let gitService = WorkplaceCreateGitServiceSpy()
        let service = WorkplaceCreateService(
            repositoryStore: repositoryStore,
            workplaceStore: stores.workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService)
        )
        var progressEvents: [WorkplaceOperationProgress] = []

        _ = try await service.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositoryIDs: [repository.id],
            branch: nil,
            progressHandler: { progress in
                progressEvents.append(progress)
            }
        )

        XCTAssertEqual(
            progressEvents,
            [
                WorkplaceOperationProgress(
                    step: .cloningRepositories,
                    completedCount: 0,
                    totalCount: 1,
                    activeRepositoryNames: ["api"]
                ),
                WorkplaceOperationProgress(
                    step: .cloningRepositories,
                    completedCount: 1,
                    totalCount: 1,
                    activeRepositoryNames: []
                ),
            ]
        )
    }

    func test_createWorkplaceRollsBackStoreWhenCloneSetupFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)

        let service = WorkplaceCreateService(
            repositoryStore: repositoryStore,
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(
                gitService: WorkplaceCreateGitServiceSpy(),
                fileSystemService: FailingCreateWorkplaceDirectoryFileSystemService()
            )
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.createWorkplace(
                name: "blog",
                rootPath: workspaceRoot.path,
                selectedRepositoryIDs: [repository.id],
                branch: nil
            )
        }

        let createdPath = URL(fileURLWithPath: workspaceRoot.path).appendingPathComponent("blog").path
        XCTAssertTrue(workplaceStore.workplaces.isEmpty)
        XCTAssertTrue(workplaceStore.syncStates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdPath))
    }
}
