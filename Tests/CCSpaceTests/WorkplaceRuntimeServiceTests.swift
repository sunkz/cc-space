import XCTest
@testable import CCSpace

private struct WorkplaceRuntimeStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor WorkplaceRuntimeGitServiceSpy: GitServicing {
    private(set) var cloneCalls: [(repositoryURL: String, directory: String)] = []
    private(set) var pullCalls: [String] = []
    private(set) var pushCalls: [String] = []
    private(set) var checkoutCalls: [(branch: String, directory: String)] = []
    private(set) var mergeCalls: [String] = []
    var checkoutError: Error?
    var checkoutErrorsByDirectory: [String: Error] = [:]
    var pushErrorsByDirectory: [String: Error] = [:]
    var mergeErrorsByDirectory: [String: Error] = [:]
    var mergeOutcomesByDirectory: [String: GitMergeDefaultBranchOutcome] = [:]
    var branchStatusesByDirectory: [String: GitBranchStatusSnapshot] = [:]
    var unreadableBranchStatusDirectories: Set<String> = []
    var currentBranchesByDirectory: [String: String] = [:]
    private(set) var defaultBranchCalls: [String] = []
    private(set) var remoteURLCalls: [String] = []
    var defaultBranchResult: String? = "main"
    var remoteURLResult: String? = "git@github.com:test/repo.git"

    func clone(repositoryURL: String, into directory: String) async throws {
        cloneCalls.append((repositoryURL: repositoryURL, directory: directory))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func pull(in directory: String) async throws {
        pullCalls.append(directory)
    }

    func push(in directory: String) async throws {
        pushCalls.append(directory)
        if let error = pushErrorsByDirectory[directory] {
            throw error
        }
    }

    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? {
        defaultBranchCalls.append(remoteURL)
        return defaultBranchResult
    }
    func defaultBranch(in directory: String) async -> String? {
        defaultBranchCalls.append(directory)
        return defaultBranchResult
    }
    func currentBranch(in directory: String) async -> String? {
        currentBranchesByDirectory[directory] ?? "main"
    }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        guard unreadableBranchStatusDirectories.contains(directory) == false else {
            return nil
        }
        return branchStatusesByDirectory[directory] ?? GitBranchStatusSnapshot(
            currentBranch: currentBranchesByDirectory[directory] ?? "main",
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false,
            hasUnpushedCommits: false,
            isBehindRemote: false
        )
    }
    func branches(in directory: String) async -> [String] { ["main", "release"] }
    func remoteURL(in directory: String) async -> String? {
        remoteURLCalls.append(directory)
        return remoteURLResult
    }
    func checkoutBranch(_ branch: String, in directory: String) async throws {
        checkoutCalls.append((branch: branch, directory: directory))
        if let directoryError = checkoutErrorsByDirectory[directory] {
            throw directoryError
        }
        if let checkoutError {
            throw checkoutError
        }
    }
    func createLocalBranch(_ branch: String, in directory: String) async throws {
        checkoutCalls.append((branch: branch, directory: directory))
        if let directoryError = checkoutErrorsByDirectory[directory] {
            throw directoryError
        }
        if let checkoutError {
            throw checkoutError
        }
    }

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        mergeCalls.append(directory)
        if let error = mergeErrorsByDirectory[directory] {
            throw error
        }
        return mergeOutcomesByDirectory[directory] ?? .merged
    }

    func cloneDirectories() async -> [String] {
        cloneCalls.map(\.directory)
    }

    func pulledDirectories() async -> [String] {
        pullCalls
    }

    func pushedDirectories() async -> [String] {
        pushCalls
    }

    func checkedOutBranches() async -> [(branch: String, directory: String)] {
        checkoutCalls
    }

    func mergedDirectories() async -> [String] {
        mergeCalls
    }

    func setCheckoutError(_ error: Error?) {
        checkoutError = error
    }

    func setCheckoutError(_ error: Error?, for directory: String) {
        checkoutErrorsByDirectory[directory] = error
    }

    func setPushError(_ error: Error?, for directory: String) {
        pushErrorsByDirectory[directory] = error
    }

    func setDefaultBranchResult(_ result: String?) {
        defaultBranchResult = result
    }

    func setBranchStatus(_ status: GitBranchStatusSnapshot, for directory: String) {
        unreadableBranchStatusDirectories.remove(directory)
        branchStatusesByDirectory[directory] = status
    }

    func setCurrentBranch(_ branch: String, for directory: String) {
        currentBranchesByDirectory[directory] = branch
    }

    func setUnreadableBranchStatus(for directory: String) {
        unreadableBranchStatusDirectories.insert(directory)
        branchStatusesByDirectory.removeValue(forKey: directory)
    }

    func setMergeError(_ error: Error?, for directory: String) {
        mergeErrorsByDirectory[directory] = error
    }

    func setMergeOutcome(_ outcome: GitMergeDefaultBranchOutcome, for directory: String) {
        mergeOutcomesByDirectory[directory] = outcome
    }
}

private final class FailingRemoveFileSystemService: FileSystemServicing, @unchecked Sendable {
    private let removeError: Error

    init(removeError: Error = WorkplaceRuntimeStubError(message: "remove failed for test")) {
        self.removeError = removeError
    }

    func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }

    func removeItem(at path: String) throws {
        throw removeError
    }
}

private actor PushConcurrencyRecorder {
    private var activeCount = 0
    private var observedMaxActiveCount = 0

    func beginPush() {
        activeCount += 1
        observedMaxActiveCount = max(observedMaxActiveCount, activeCount)
    }

    func endPush() {
        activeCount -= 1
    }

    func maxActiveCount() -> Int {
        observedMaxActiveCount
    }
}

private final class ConcurrentPushGitServiceSpy: GitServicing, @unchecked Sendable {
    private let recorder = PushConcurrencyRecorder()
    private let pushDelayNanoseconds: UInt64

    init(pushDelayNanoseconds: UInt64 = 100_000_000) {
        self.pushDelayNanoseconds = pushDelayNanoseconds
    }

    func clone(repositoryURL: String, into directory: String) async throws {}

    func pull(in directory: String) async throws {}

    func push(in directory: String) async throws {
        await recorder.beginPush()
        do {
            try await Task.sleep(nanoseconds: pushDelayNanoseconds)
            await recorder.endPush()
        } catch {
            await recorder.endPush()
            throw error
        }
    }

    func isGitAvailable() async -> Bool { true }

    func defaultBranch(for remoteURL: String) async -> String? { "main" }

    func defaultBranch(in directory: String) async -> String? { "main" }

    func currentBranch(in directory: String) async -> String? { "main" }

    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        makeBranchStatus(hasUnpushedCommits: true)
    }

    func branches(in directory: String) async -> [String] { ["main"] }

    func remoteURL(in directory: String) async -> String? { "git@github.com:test/repo.git" }

    func checkoutBranch(_ branch: String, in directory: String) async throws {}

    func createLocalBranch(_ branch: String, in directory: String) async throws {}

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        .merged
    }

    func maxActiveCount() async -> Int {
        await recorder.maxActiveCount()
    }
}

@MainActor
final class WorkplaceRuntimeServiceTests: XCTestCase {
    func test_retryCloneOnlyReplacesTargetRepositoryState() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [apiRepository, webRepository]
        )

        let apiPath = URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            atPath: apiPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var apiState = try XCTUnwrap(syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore))
        apiState.status = .success
        apiState.lastError = nil
        apiState.lastSyncedAt = Date(timeIntervalSince1970: 100)
        try workplaceStore.updateSyncState(apiState)

        var webState = try XCTUnwrap(syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore))
        webState.status = .failed
        webState.lastError = "clone failed"
        try workplaceStore.updateSyncState(webState)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.retryClone(repository: webRepository, in: workplace)

        let persistedAPIState = try XCTUnwrap(
            syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        let persistedWebState = try XCTUnwrap(
            syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )

        XCTAssertEqual(persistedAPIState, apiState)
        XCTAssertEqual(persistedWebState.status, .success)
        XCTAssertNil(persistedWebState.lastError)
        XCTAssertNotNil(persistedWebState.lastSyncedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedWebState.localPath))

        let cloneDirectories = await gitService.cloneDirectories()
        XCTAssertEqual(cloneDirectories, [persistedWebState.localPath])
    }

    func test_retryCloneRemovesExistingLocalDirectoryBeforeReclone() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let staleMarker = URL(fileURLWithPath: localPath).appendingPathComponent("stale.txt")
        FileManager.default.createFile(atPath: staleMarker.path, contents: Data("stale".utf8))

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "checkout failed"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.retryClone(repository: repository, in: workplace)

        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarker.path))
    }

    func test_pullRepositoriesOnlyPullsRequestedRepository() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
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

        let baselineDate = Date(timeIntervalSince1970: 123)
        var apiState = try XCTUnwrap(syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore))
        apiState.status = .success
        apiState.lastSyncedAt = baselineDate
        try workplaceStore.updateSyncState(apiState)

        var webState = try XCTUnwrap(syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore))
        webState.status = .success
        webState.lastSyncedAt = nil
        try workplaceStore.updateSyncState(webState)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = await service.pullRepositories(in: workplace, repositoryID: webRepository.id)

        let persistedAPIState = try XCTUnwrap(
            syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        let persistedWebState = try XCTUnwrap(
            syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )

        XCTAssertEqual(persistedAPIState.lastSyncedAt, baselineDate)
        XCTAssertEqual(persistedAPIState.status, .success)
        XCTAssertEqual(persistedWebState.status, .success)
        XCTAssertNotNil(persistedWebState.lastSyncedAt)
        XCTAssertEqual(result, RepositoryPullResult(successCount: 1, failedCount: 0, skippedCount: 0))

        let pulledDirectories = await gitService.pulledDirectories()
        XCTAssertEqual(pulledDirectories, [webPath])
    }

    func test_pushRepositoriesOnlyPushesRepositoriesThatNeedPush() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let apiRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "api" })
        let webRepository = try XCTUnwrap(repositoryStore.repositories.first { $0.repoName == "web" })
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
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

        let baselineDate = Date(timeIntervalSince1970: 123)
        var apiState = try XCTUnwrap(syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore))
        apiState.status = .success
        apiState.localPath = apiPath
        apiState.lastSyncedAt = baselineDate
        try workplaceStore.updateSyncState(apiState)

        var webState = try XCTUnwrap(syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore))
        webState.status = .failed
        webState.localPath = webPath
        webState.lastError = "stale push error"
        webState.lastSyncedAt = baselineDate
        try workplaceStore.updateSyncState(webState)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setBranchStatus(makeBranchStatus(hasUnpushedCommits: true), for: apiPath)
        await gitService.setBranchStatus(makeBranchStatus(), for: webPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepositories(in: workplace)

        let persistedAPIState = try XCTUnwrap(
            syncState(for: apiRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        let persistedWebState = try XCTUnwrap(
            syncState(for: webRepository.id, workplaceID: workplace.id, in: workplaceStore)
        )

        XCTAssertEqual(result, RepositoryPushResult(successCount: 1, failedCount: 0, skippedCount: 1))
        XCTAssertEqual(persistedAPIState.status, .success)
        XCTAssertNil(persistedAPIState.lastError)
        XCTAssertNotNil(persistedAPIState.lastSyncedAt)
        XCTAssertEqual(persistedWebState.status, .success)
        XCTAssertNil(persistedWebState.lastError)
        XCTAssertEqual(persistedWebState.lastSyncedAt, baselineDate)

        let pushedDirectories = await gitService.pushedDirectories()
        XCTAssertEqual(pushedDirectories, [apiPath])
    }

    func test_pushRepositoriesMarksRepositoryFailedWhenGitStatusIsUnreadable() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")

        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        state.lastError = nil
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setUnreadableBranchStatus(for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepositories(in: workplace)

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        let pushedDirectories = await gitService.pushedDirectories()

        XCTAssertEqual(result, RepositoryPushResult(successCount: 0, failedCount: 1, skippedCount: 0))
        XCTAssertEqual(persistedState.status, .failed)
        XCTAssertEqual(persistedState.lastError, "无法读取仓库 Git 状态")
        XCTAssertTrue(pushedDirectories.isEmpty)
    }

    func test_pushRepositoriesPersistsLastErrorWhenPushFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setBranchStatus(makeBranchStatus(hasUnpushedCommits: true), for: localPath)
        await gitService.setPushError(WorkplaceRuntimeStubError(message: "push failed"), for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepositories(in: workplace)

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(result, RepositoryPushResult(successCount: 0, failedCount: 1, skippedCount: 0))
        XCTAssertEqual(persistedState.status, .failed)
        XCTAssertEqual(persistedState.lastError, "push failed")

        let pushedDirectories = await gitService.pushedDirectories()
        XCTAssertEqual(pushedDirectories, [localPath])
    }

    func test_pushRepositoriesLimitsConcurrentPushesToFour() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        for index in 0..<8 {
            try repositoryStore.addRepository(gitURL: "git@github.com:org/repo\(index).git")
        }

        let repositories = repositoryStore.repositories.sorted { $0.repoName < $1.repoName }
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories
        )

        for repository in repositories {
            let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
            try FileManager.default.createDirectory(
                atPath: localPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            var state = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            state.status = .failed
            state.localPath = localPath
            state.lastError = "stale error"
            try workplaceStore.updateSyncState(state)
        }

        let gitService = ConcurrentPushGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepositories(in: workplace)

        XCTAssertEqual(
            result,
            RepositoryPushResult(successCount: 8, failedCount: 0, skippedCount: 0)
        )
        let maxActiveCount = await gitService.maxActiveCount()
        XCTAssertEqual(maxActiveCount, 4)

        for repository in repositories {
            let persistedState = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            XCTAssertEqual(persistedState.status, .success)
            XCTAssertNil(persistedState.lastError)
        }
    }

    func test_pushRepositoryReturnsSkippedWhenRepositoryDoesNotNeedPush() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "push failed"
        state.lastSyncedAt = Date(timeIntervalSince1970: 123)
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setBranchStatus(makeBranchStatus(), for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepository(for: state, in: workplace)

        XCTAssertEqual(result, .skipped)
        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.status, .success)
        XCTAssertNil(persistedState.lastError)
        XCTAssertEqual(persistedState.lastSyncedAt, state.lastSyncedAt)

        let pushedDirectories = await gitService.pushedDirectories()
        XCTAssertTrue(pushedDirectories.isEmpty)
    }

    func test_pushRepositoryPushesCurrentRepositoryAndClearsLastError() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setBranchStatus(makeBranchStatus(hasUnpushedCommits: true), for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.pushRepository(for: state, in: workplace)

        XCTAssertEqual(result, .pushed)
        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.status, .success)
        XCTAssertNil(persistedState.lastError)
        XCTAssertNotNil(persistedState.lastSyncedAt)

        let pushedDirectories = await gitService.pushedDirectories()
        XCTAssertEqual(pushedDirectories, [localPath])
    }

    func test_deleteWorkplaceRemovesDirectoriesAndStoreRecordsWhenRequested() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: WorkplaceRuntimeGitServiceSpy()),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.deleteWorkplace(workplace, removeLocalDirectories: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workplace.path))
        XCTAssertFalse(workplaceStore.workplaces.contains { $0.id == workplace.id })
        XCTAssertFalse(workplaceStore.syncStates.contains { $0.workplaceID == workplace.id })
    }

    func test_deleteWorkplaceKeepsDirectoriesWhenNotRequested() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: WorkplaceRuntimeGitServiceSpy()),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.deleteWorkplace(workplace, removeLocalDirectories: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: workplace.path))
        XCTAssertFalse(workplaceStore.workplaces.contains { $0.id == workplace.id })
        XCTAssertFalse(workplaceStore.syncStates.contains { $0.workplaceID == workplace.id })
    }

    func test_deleteWorkplaceRestoresSyncStatesWhenLocalRemovalFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: workplace.path).appendingPathComponent("api").path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var originalState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        originalState.status = .failed
        originalState.lastError = "existing error"
        try workplaceStore.updateSyncState(originalState)

        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(
                gitService: WorkplaceRuntimeGitServiceSpy(),
                fileSystemService: FailingRemoveFileSystemService()
            ),
            workplaceRootPath: workspaceRoot.path
        )

        await XCTAssertThrowsErrorAsync {
            try await service.deleteWorkplace(workplace, removeLocalDirectories: true)
        }

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState, originalState)
        XCTAssertTrue(workplaceStore.workplaces.contains { $0.id == workplace.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workplace.path))
    }

    func test_deleteWorkplaceReportsBusyDirectoryWhenRemovalFailsWithBusyError() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(
                gitService: WorkplaceRuntimeGitServiceSpy(),
                fileSystemService: FailingRemoveFileSystemService(
                    removeError: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
                )
            ),
            workplaceRootPath: workspaceRoot.path
        )

        do {
            try await service.deleteWorkplace(workplace, removeLocalDirectories: true)
            XCTFail("Expected busy directory error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                """
                工作区目录正在被其他程序使用，请关闭占用该目录的终端、IDE 或本地服务后重试。
                目录：\(workplace.path)
                """
            )
        }
    }

    func test_switchBranchChecksOutTargetBranchAndClearsLastError() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.switchBranch(for: state, in: workplace, to: "release")

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertNil(persistedState.lastError)
        XCTAssertEqual(persistedState.status, .success)

        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.count, 1)
        XCTAssertEqual(checkoutCalls.first?.branch, "release")
        XCTAssertEqual(checkoutCalls.first?.directory, localPath)
    }

    func test_switchBranchPersistsLastErrorWhenCheckoutFails() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCheckoutError(WorkplaceRuntimeStubError(message: "checkout failed"))
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        await XCTAssertThrowsErrorAsync {
            try await service.switchBranch(for: state, in: workplace, to: "release")
        }

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.lastError, "checkout failed")
        XCTAssertEqual(persistedState.status, .failed)
    }

    func test_switchBranchRejectsRepositoryWithUncommittedChanges() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("main", for: localPath)
        await gitService.setBranchStatus(
            makeBranchStatus(currentBranch: "main", hasUncommittedChanges: true),
            for: localPath
        )
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        await XCTAssertThrowsErrorAsync {
            try await service.switchBranch(for: state, in: workplace, to: "release")
        }

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.lastError, "仓库有未提交的改动，无法切换分支")
        XCTAssertEqual(persistedState.status, .failed)

        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertTrue(checkoutCalls.isEmpty)
    }

    func test_switchBranchSkipsCheckoutWhenRepositoryAlreadyOnTargetBranch() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("release", for: localPath)
        await gitService.setBranchStatus(
            makeBranchStatus(currentBranch: "release", hasUncommittedChanges: true),
            for: localPath
        )
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.switchBranch(for: state, in: workplace, to: "release")

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.status, .success)
        XCTAssertNil(persistedState.lastError)

        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertTrue(checkoutCalls.isEmpty)
    }

    func test_switchRepositoriesToWorkBranchChecksOutAllLocalRepositories() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let repositories = repositoryStore.repositories.sorted { $0.repoName < $1.repoName }
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories,
            branch: "release/88"
        )

        let localPaths = repositories.map {
            URL(fileURLWithPath: workplace.path).appendingPathComponent($0.repoName).path
        }
        for localPath in localPaths {
            try FileManager.default.createDirectory(
                atPath: localPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        for repository in repositories {
            var state = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            state.status = .failed
            state.localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
            state.lastError = "old error"
            try workplaceStore.updateSyncState(state)
        }

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.switchRepositoriesToWorkBranch(in: workplace)

        XCTAssertEqual(result, WorkplaceBulkBranchSwitchResult(successCount: 2, failedCount: 0))
        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.map(\.branch), ["release/88", "release/88"])

        for repository in repositories {
            let persistedState = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            XCTAssertEqual(persistedState.status, .success)
            XCTAssertNil(persistedState.lastError)
        }
    }

    func test_switchRepositoriesToWorkBranchPersistsDirtyRepositoryFailure() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let repositories = repositoryStore.repositories.sorted { $0.repoName < $1.repoName }
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories,
            branch: "release/88"
        )

        let localPaths = repositories.map {
            URL(fileURLWithPath: workplace.path).appendingPathComponent($0.repoName).path
        }
        for localPath in localPaths {
            try FileManager.default.createDirectory(
                atPath: localPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        for (index, repository) in repositories.enumerated() {
            var state = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            state.status = .success
            state.localPath = localPaths[index]
            try workplaceStore.updateSyncState(state)
        }

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("main", for: localPaths[0])
        await gitService.setCurrentBranch("main", for: localPaths[1])
        await gitService.setBranchStatus(
            makeBranchStatus(currentBranch: "main", hasUncommittedChanges: true),
            for: localPaths[0]
        )
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.switchRepositoriesToWorkBranch(in: workplace)

        XCTAssertEqual(result, WorkplaceBulkBranchSwitchResult(successCount: 1, failedCount: 1))

        let failedState = try XCTUnwrap(
            syncState(for: repositories[0].id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(failedState.status, .failed)
        XCTAssertEqual(failedState.lastError, "仓库有未提交的改动，无法切换分支")

        let succeededState = try XCTUnwrap(
            syncState(for: repositories[1].id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(succeededState.status, .success)
        XCTAssertNil(succeededState.lastError)

        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.count, 1)
        XCTAssertEqual(checkoutCalls.first?.directory, localPaths[1])
    }

    func test_switchRepositoryToWorkBranchChecksOutConfiguredBranch() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository],
            branch: "01"
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let branch = try await service.switchRepositoryToWorkBranch(
            for: state,
            in: workplace,
            workBranch: "01"
        )

        XCTAssertEqual(branch, "01")
        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.first?.branch, "01")

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertNil(persistedState.lastError)
    }

    func test_switchRepositoriesToDefaultBranchUsesResolvedDefaultBranch() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository],
            branch: "release/88"
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("feature/api", for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.switchRepositoriesToDefaultBranch(in: workplace)

        XCTAssertEqual(result, WorkplaceBulkBranchSwitchResult(successCount: 1, failedCount: 0))
        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.first?.branch, "main")
        let defaultBranchCalls = await gitService.defaultBranchCalls
        XCTAssertEqual(defaultBranchCalls, [localPath])
    }

    func test_switchRepositoryToDefaultBranchUsesResolvedDefaultBranch() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("feature/api", for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let branch = try await service.switchRepositoryToDefaultBranch(for: state, in: workplace)

        XCTAssertEqual(branch, "main")
        let checkoutCalls = await gitService.checkedOutBranches()
        XCTAssertEqual(checkoutCalls.first?.branch, "main")
    }

    func test_switchRepositoriesToDefaultBranchPersistsResolverFailure() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setDefaultBranchResult(nil)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.switchRepositoriesToDefaultBranch(in: workplace)

        XCTAssertEqual(result, WorkplaceBulkBranchSwitchResult(successCount: 0, failedCount: 1))
        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.lastError, WorkplaceRuntimeServiceError.missingDefaultBranch.localizedDescription)
        XCTAssertEqual(persistedState.status, .failed)
    }

    func test_mergeDefaultBranchIntoCurrentSkipsDefaultBranchRepositories() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let repositories = repositoryStore.repositories.sorted { $0.repoName < $1.repoName }
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories
        )

        let localPaths = repositories.map {
            URL(fileURLWithPath: workplace.path).appendingPathComponent($0.repoName).path
        }
        for localPath in localPaths {
            try FileManager.default.createDirectory(
                atPath: localPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        for (index, repository) in repositories.enumerated() {
            var state = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            state.status = .failed
            state.localPath = localPaths[index]
            state.lastError = "old error"
            try workplaceStore.updateSyncState(state)
        }

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("main", for: localPaths[0])
        await gitService.setCurrentBranch("feature/web", for: localPaths[1])
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.mergeDefaultBranchIntoCurrent(in: workplace)

        XCTAssertEqual(
            result,
            WorkplaceBulkBranchSwitchResult(successCount: 1, failedCount: 0, skippedCount: 1)
        )
        let mergeCalls = await gitService.mergedDirectories()
        XCTAssertEqual(mergeCalls, [localPaths[1]])

        for repository in repositories {
            let persistedState = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            XCTAssertEqual(persistedState.status, .success)
            XCTAssertNil(persistedState.lastError)
        }
    }

    func test_mergeDefaultBranchIntoCurrentForRepositoryReturnsOutcomeAndClearsLastError() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = localPath
        state.lastError = "old error"
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("main", for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let outcome = try await service.mergeDefaultBranchIntoCurrent(for: state, in: workplace)

        XCTAssertEqual(outcome, .skipped)
        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.status, .success)
        XCTAssertNil(persistedState.lastError)

        let mergeCalls = await gitService.mergedDirectories()
        XCTAssertTrue(mergeCalls.isEmpty)
    }

    func test_mergeDefaultBranchIntoCurrentForRepositoryRejectsDirtyWorktree() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("feature/test", for: localPath)
        await gitService.setBranchStatus(
            makeBranchStatus(currentBranch: "feature/test", hasUncommittedChanges: true),
            for: localPath
        )
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.mergeDefaultBranchIntoCurrent(for: state, in: workplace)
        }

        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.status, .failed)
        XCTAssertEqual(persistedState.lastError, "仓库有未提交的改动，无法合并默认分支")

        let mergeCalls = await gitService.mergedDirectories()
        XCTAssertTrue(mergeCalls.isEmpty)
    }

    func test_mergeDefaultBranchIntoCurrentPersistsFailuresPerRepository() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let localPath = URL(fileURLWithPath: workplace.path).appendingPathComponent(repository.repoName).path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .success
        state.localPath = localPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("feature/api", for: localPath)
        await gitService.setMergeError(WorkplaceRuntimeStubError(message: "merge conflict"), for: localPath)
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.mergeDefaultBranchIntoCurrent(in: workplace)

        XCTAssertEqual(
            result,
            WorkplaceBulkBranchSwitchResult(successCount: 0, failedCount: 1, skippedCount: 0)
        )
        let persistedState = try XCTUnwrap(
            syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(persistedState.lastError, "merge conflict")
        XCTAssertEqual(persistedState.status, .failed)
    }

    func test_mergeDefaultBranchIntoCurrentPersistsDirtyWorktreeFailure() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")

        let repositories = repositoryStore.repositories.sorted { $0.repoName < $1.repoName }
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: repositories
        )

        let localPaths = repositories.map {
            URL(fileURLWithPath: workplace.path).appendingPathComponent($0.repoName).path
        }
        for localPath in localPaths {
            try FileManager.default.createDirectory(
                atPath: localPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        for (index, repository) in repositories.enumerated() {
            var state = try XCTUnwrap(
                syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore)
            )
            state.status = .success
            state.localPath = localPaths[index]
            try workplaceStore.updateSyncState(state)
        }

        let gitService = WorkplaceRuntimeGitServiceSpy()
        await gitService.setCurrentBranch("feature/api", for: localPaths[0])
        await gitService.setCurrentBranch("feature/web", for: localPaths[1])
        await gitService.setBranchStatus(
            makeBranchStatus(currentBranch: "feature/api", hasUncommittedChanges: true),
            for: localPaths[0]
        )
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        let result = try await service.mergeDefaultBranchIntoCurrent(in: workplace)

        XCTAssertEqual(
            result,
            WorkplaceBulkBranchSwitchResult(successCount: 1, failedCount: 1, skippedCount: 0)
        )

        let failedState = try XCTUnwrap(
            syncState(for: repositories[0].id, workplaceID: workplace.id, in: workplaceStore)
        )
        XCTAssertEqual(failedState.status, .failed)
        XCTAssertEqual(failedState.lastError, "仓库有未提交的改动，无法合并默认分支")

        let mergeCalls = await gitService.mergedDirectories()
        XCTAssertEqual(mergeCalls, [localPaths[1]])
    }

    func test_retryCloneDoesNotRemoveCorruptedPathOutsideWorkplace() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot

        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        let expectedLocalPath = URL(fileURLWithPath: workplace.path)
            .appendingPathComponent(repository.repoName)
            .path
        try FileManager.default.createDirectory(
            atPath: expectedLocalPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let expectedMarker = URL(fileURLWithPath: expectedLocalPath).appendingPathComponent("stale.txt")
        FileManager.default.createFile(atPath: expectedMarker.path, contents: Data("stale".utf8))

        let corruptedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        try FileManager.default.createDirectory(
            atPath: corruptedPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let corruptedMarker = URL(fileURLWithPath: corruptedPath).appendingPathComponent("keep.txt")
        FileManager.default.createFile(atPath: corruptedMarker.path, contents: Data("keep".utf8))

        var state = try XCTUnwrap(syncState(for: repository.id, workplaceID: workplace.id, in: workplaceStore))
        state.status = .failed
        state.localPath = corruptedPath
        try workplaceStore.updateSyncState(state)

        let gitService = WorkplaceRuntimeGitServiceSpy()
        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: gitService),
            workplaceRootPath: workspaceRoot.path
        )

        try await service.retryClone(repository: repository, in: workplace)

        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptedMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedMarker.path))
    }

    func test_deleteWorkplaceRejectsPathOutsideConfiguredRoot() async throws {
        let stores = try makeServiceStores()
        let repositoryStore = stores.repositoryStore
        let workplaceStore = stores.workplaceStore
        let workspaceRoot = stores.workspaceRoot
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        try repositoryStore.addRepository(gitURL: "git@github.com:org/api.git")
        let repository = try XCTUnwrap(repositoryStore.repositories.first)
        let workplace = try workplaceStore.createWorkplace(
            name: "blog",
            rootPath: workspaceRoot.path,
            selectedRepositories: [repository]
        )

        try FileManager.default.createDirectory(
            atPath: workplace.path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let service = WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: WorkplaceRuntimeGitServiceSpy()),
            workplaceRootPath: otherRoot.path
        )

        do {
            try await service.deleteWorkplace(workplace, removeLocalDirectories: true)
            XCTFail("Expected unmanaged path error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                """
                当前工作区目录不在已配置的根目录内，删除按钮默认会连同本地目录一起删除，因此被安全拦截。
                根目录：\(otherRoot.path)
                工作区目录：\(workplace.path)
                """
            )
        }

        XCTAssertTrue(workplaceStore.workplaces.contains { $0.id == workplace.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workplace.path))
    }

    private func syncState(
        for repositoryID: UUID,
        workplaceID: UUID,
        in workplaceStore: WorkplaceStore
    ) -> RepositorySyncState? {
        workplaceStore.syncStates.first {
            $0.workplaceID == workplaceID && $0.repositoryID == repositoryID
        }
    }
}

private func makeBranchStatus(
    currentBranch: String = "feature/test",
    hasRemoteTrackingBranch: Bool = true,
    hasUncommittedChanges: Bool = false,
    hasUnpushedCommits: Bool = false
) -> GitBranchStatusSnapshot {
    GitBranchStatusSnapshot(
        currentBranch: currentBranch,
        hasRemoteTrackingBranch: hasRemoteTrackingBranch,
        hasUncommittedChanges: hasUncommittedChanges,
        hasUnpushedCommits: hasUnpushedCommits,
        isBehindRemote: false
    )
}
