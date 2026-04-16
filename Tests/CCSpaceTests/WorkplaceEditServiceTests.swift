import XCTest
@testable import CCSpace

private struct WorkplaceEditStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor WorkplaceEditGitServiceSpy: GitServicing {
    private(set) var cloneCalls: [(repositoryURL: String, directory: String)] = []
    private(set) var checkoutCalls: [(branch: String, directory: String)] = []
    var currentBranchByDirectory: [String: String] = [:]
    var branchStatusByDirectory: [String: GitBranchStatusSnapshot] = [:]

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
    func currentBranch(in directory: String) async -> String? {
        currentBranchByDirectory[directory] ?? "main"
    }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        branchStatusByDirectory[directory] ?? GitBranchStatusSnapshot(
            currentBranch: currentBranchByDirectory[directory] ?? "main",
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
        currentBranchByDirectory[directory] = branch
    }

    func createLocalBranch(_ branch: String, in directory: String) async throws {
        checkoutCalls.append((branch: branch, directory: directory))
        currentBranchByDirectory[directory] = branch
    }

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        .merged
    }

    func cloneDirectories() async -> [String] {
        cloneCalls.map(\.directory)
    }

    func checkoutDirectories() async -> [String] {
        checkoutCalls.map(\.directory)
    }

    func setCurrentBranch(_ branch: String, for directory: String) {
        currentBranchByDirectory[directory] = branch
    }

    func setBranchStatus(_ status: GitBranchStatusSnapshot, for directory: String) {
        branchStatusByDirectory[directory] = status
    }
}

private final class FailingCreateDirectoryFileSystemService: FileSystemServicing {
    func createDirectory(at path: String) throws {
        throw WorkplaceEditStubError(message: "create directory failed for test")
    }

    func removeItem(at path: String) throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }
}

@MainActor
final class WorkplaceEditServiceTests: XCTestCase {
    func test_saveWorkplaceEditRenamesUpdatesBranchAndClonesAddedRepository() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var existingState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == apiRepository.id
            }
        )
        existingState.status = .success
        existingState.lastSyncedAt = .now
        try workplaceStore.updateSyncState(existingState)

        let gitService = WorkplaceEditGitServiceSpy()
        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        try await service.saveWorkplaceEdit(
            workplaceID: workplace.id,
            name: "ios-prod",
            selectedRepositoryIDs: [apiRepository.id, webRepository.id],
            branch: "release"
        )

        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(updatedWorkplace.name, "ios-prod")
        XCTAssertEqual(updatedWorkplace.branch, "release")
        XCTAssertEqual(updatedWorkplace.selectedRepositoryIDs, [apiRepository.id, webRepository.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workplace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: updatedWorkplace.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: updatedWorkplace.path).appendingPathComponent("web").path
            )
        )

        let syncStates = workplaceStore.syncStates
            .filter { $0.workplaceID == workplace.id }
            .sorted { $0.localPath < $1.localPath }
        XCTAssertEqual(syncStates.count, 2)
        XCTAssertTrue(syncStates.allSatisfy { $0.localPath.hasPrefix(updatedWorkplace.path) })

        let checkoutDirectories = await gitService.checkoutDirectories()
        XCTAssertTrue(
            checkoutDirectories.contains(
                URL(fileURLWithPath: updatedWorkplace.path).appendingPathComponent("api").path
            )
        )
        XCTAssertTrue(
            checkoutDirectories.contains(
                URL(fileURLWithPath: updatedWorkplace.path).appendingPathComponent("web").path
            )
        )
    }

    func test_saveWorkplaceEditRestoresFilesystemAndStoreWhenCloneSetupFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        let originalRepoPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: originalRepoPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let gitService = WorkplaceEditGitServiceSpy()
        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(
                gitService: gitService,
                fileSystemService: FailingCreateDirectoryFileSystemService()
            ),
            gitService: gitService
        )

        await XCTAssertThrowsErrorAsync {
            try await service.saveWorkplaceEdit(
                workplaceID: workplace.id,
                name: "ios-prod",
                selectedRepositoryIDs: [webRepository.id],
                branch: nil
            )
        }

        let persistedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(persistedWorkplace.name, "ios-dev")
        XCTAssertEqual(persistedWorkplace.path, workplace.path)
        XCTAssertEqual(persistedWorkplace.selectedRepositoryIDs, [apiRepository.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workplace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalRepoPath))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: workspaceRoot.path).appendingPathComponent("ios-prod").path
            )
        )

        let syncStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }
        XCTAssertEqual(syncStates.count, 1)
        XCTAssertEqual(syncStates.first?.repositoryID, apiRepository.id)
        XCTAssertEqual(syncStates.first?.localPath, originalRepoPath)
    }

    func test_saveWorkplaceEditSkipsCheckoutWhenRepositoryAlreadyOnTargetBranch() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        let apiPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: apiPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var existingState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == apiRepository.id
            }
        )
        existingState.status = .success
        existingState.localPath = apiPath
        try workplaceStore.updateSyncState(existingState)

        let gitService = WorkplaceEditGitServiceSpy()
        await gitService.setCurrentBranch("release", for: apiPath)

        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        try await service.saveWorkplaceEdit(
            workplaceID: workplace.id,
            name: "ios-dev",
            selectedRepositoryIDs: [apiRepository.id],
            branch: "release"
        )

        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        let checkoutDirectories = await gitService.checkoutDirectories()
        XCTAssertEqual(updatedWorkplace.branch, "release")
        XCTAssertTrue(checkoutDirectories.isEmpty)
    }

    func test_saveWorkplaceEditPersistsDirtyRepositoryBranchSwitchFailure() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        let apiPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: apiPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var existingState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == apiRepository.id
            }
        )
        existingState.status = .success
        existingState.localPath = apiPath
        try workplaceStore.updateSyncState(existingState)

        let gitService = WorkplaceEditGitServiceSpy()
        await gitService.setCurrentBranch("main", for: apiPath)
        await gitService.setBranchStatus(
            GitBranchStatusSnapshot(
                currentBranch: "main",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: true,
                hasUnpushedCommits: false,
                isBehindRemote: false
            ),
            for: apiPath
        )

        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        try await service.saveWorkplaceEdit(
            workplaceID: workplace.id,
            name: "ios-dev",
            selectedRepositoryIDs: [apiRepository.id],
            branch: "release"
        )

        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(updatedWorkplace.branch, "release")

        let updatedState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == apiRepository.id
            }
        )
        XCTAssertEqual(updatedState.status, .failed)
        XCTAssertEqual(updatedState.lastError, "仓库有未提交的改动，无法切换分支")

        let checkoutDirectories = await gitService.checkoutDirectories()
        XCTAssertTrue(checkoutDirectories.isEmpty)
    }

    func test_saveWorkplaceEditRemovesDeselectedRepositoryAndDeletesLocalDirectory() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository, webRepository]
        )

        let apiPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        let webPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("web").path
        try FileManager.default.createDirectory(
            atPath: apiPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            atPath: webPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let gitService = WorkplaceEditGitServiceSpy()
        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        try await service.saveWorkplaceEdit(
            workplaceID: workplace.id,
            name: "ios-dev",
            selectedRepositoryIDs: [apiRepository.id],
            branch: nil
        )

        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(updatedWorkplace.selectedRepositoryIDs, [apiRepository.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: apiPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: webPath))

        let remainingStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }
        XCTAssertEqual(remainingStates.map(\.repositoryID), [apiRepository.id])
    }

    func test_saveWorkplaceEditRestoresCheckedOutBranchesWhenLaterStepFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        let apiPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: apiPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var existingState = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == apiRepository.id
            }
        )
        existingState.status = .success
        existingState.localPath = apiPath
        try workplaceStore.updateSyncState(existingState)

        let gitService = WorkplaceEditGitServiceSpy()
        await gitService.setCurrentBranch("main", for: apiPath)

        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(
                gitService: gitService,
                fileSystemService: FailingCreateDirectoryFileSystemService()
            ),
            gitService: gitService
        )

        await XCTAssertThrowsErrorAsync {
            try await service.saveWorkplaceEdit(
                workplaceID: workplace.id,
                name: workplace.name,
                selectedRepositoryIDs: [apiRepository.id, webRepository.id],
                branch: "release"
            )
        }

        let checkoutDirectories = await gitService.checkoutDirectories()
        let currentBranch = await gitService.currentBranch(in: apiPath)

        XCTAssertEqual(checkoutDirectories, [apiPath, apiPath])
        XCTAssertEqual(currentBranch, "main")

        let persistedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(persistedWorkplace.branch, nil)
        XCTAssertEqual(persistedWorkplace.selectedRepositoryIDs, [apiRepository.id])
    }

    func test_saveWorkplaceEditRejectsRemovingAllRepositories() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository]
        )

        let gitService = WorkplaceEditGitServiceSpy()
        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        do {
            try await service.saveWorkplaceEdit(
                workplaceID: workplace.id,
                name: workplace.name,
                selectedRepositoryIDs: [],
                branch: workplace.branch
            )
            XCTFail("expected noRepositoriesSelected")
        } catch {
            XCTAssertEqual(error as? WorkplaceStoreError, .noRepositoriesSelected)
        }
    }

    func test_saveWorkplaceEditRejectsInvalidName() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: WorkplaceEditGitServiceSpy()),
            gitService: WorkplaceEditGitServiceSpy()
        )

        do {
            try await service.saveWorkplaceEdit(
                workplaceID: workplace.id,
                name: "../ios-prod",
                selectedRepositoryIDs: [repository.id],
                branch: workplace.branch
            )
            XCTFail("expected invalidName")
        } catch {
            XCTAssertEqual(error as? WorkplaceStoreError, .invalidName)
        }
    }

    func test_saveWorkplaceEditRejectsUnsafeTrackedRepositoryPath() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let outsidePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        try FileManager.default.createDirectory(
            atPath: outsidePath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(
            workplaceStore.syncStates.first {
                $0.workplaceID == workplace.id && $0.repositoryID == repository.id
            }
        )
        state.status = .success
        state.localPath = outsidePath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceEditGitServiceSpy()
        let service = WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            gitService: gitService
        )

        do {
            try await service.saveWorkplaceEdit(
                workplaceID: workplace.id,
                name: workplace.name,
                selectedRepositoryIDs: [repository.id],
                branch: workplace.branch
            )
            XCTFail("expected unsafeManagedPath")
        } catch {
            XCTAssertEqual(error as? LocalPathSafetyError, .unsafeManagedPath)
        }
    }
}
