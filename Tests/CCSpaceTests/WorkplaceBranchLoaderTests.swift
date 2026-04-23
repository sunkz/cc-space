import XCTest
@testable import CCSpace

private actor WorkplaceBranchLoaderGitServiceSpy: GitServicing {
    private let operationDelay: Duration
    private(set) var activeOperationCount = 0
    private(set) var maxActiveOperationCount = 0
    private(set) var currentBranchCalls: [String] = []
    private var directoriesWithoutStatus = Set<String>()
    private var branchesByDirectory: [String: [String]] = [:]
    private var currentBranchByDirectory: [String: String] = [:]

    init(operationDelay: Duration = .milliseconds(20)) {
        self.operationDelay = operationDelay
    }

    func clone(repositoryURL: String, into directory: String) async throws {}
    func pull(in directory: String) async throws {}
    func push(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { "main" }
    func defaultBranch(in directory: String) async -> String? { "main" }

    func currentBranch(in directory: String) async -> String? {
        currentBranchCalls.append(directory)
        return currentBranchByDirectory[directory] ?? "main"
    }

    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        activeOperationCount += 1
        maxActiveOperationCount = max(maxActiveOperationCount, activeOperationCount)
        defer { activeOperationCount -= 1 }

        try? await Task.sleep(for: operationDelay)

        guard directoriesWithoutStatus.contains(directory) == false else {
            return nil
        }

        return GitBranchStatusSnapshot(
            currentBranch: currentBranchByDirectory[directory] ?? "main",
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false,
            hasUnpushedCommits: false,
            isBehindRemote: false
        )
    }

    func branches(in directory: String) async -> [String] {
        activeOperationCount += 1
        maxActiveOperationCount = max(maxActiveOperationCount, activeOperationCount)
        defer { activeOperationCount -= 1 }

        try? await Task.sleep(for: operationDelay)
        return branchesByDirectory[directory] ?? ["main"]
    }

    func remoteURL(in directory: String) async -> String? { "git@github.com:test/repo.git" }
    func checkoutBranch(_ branch: String, in directory: String) async throws {}
    func createLocalBranch(_ branch: String, in directory: String) async throws {}
    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }
    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome { .merged }
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }

    func setBranches(_ branches: [String], for directory: String) {
        branchesByDirectory[directory] = branches
    }

    func setCurrentBranch(_ branch: String, for directory: String) {
        currentBranchByDirectory[directory] = branch
    }

    func removeBranchStatus(for directory: String) {
        directoriesWithoutStatus.insert(directory)
    }
}

final class WorkplaceBranchLoaderTests: XCTestCase {
    func test_loaderLimitsConcurrentGitRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let workplaceID = UUID()
        let states = try (0..<(WorkplaceBranchLoader.maxConcurrentSnapshotLoads + 3)).map { index in
            let directory = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: UUID(),
                status: .success,
                localPath: directory.path,
                lastError: nil,
                lastSyncedAt: nil
            )
        }

        let gitService = WorkplaceBranchLoaderGitServiceSpy()
        for state in states {
            await gitService.setCurrentBranch("main", for: state.localPath)
            await gitService.setBranches(["main", "release"], for: state.localPath)
        }

        let snapshots = await WorkplaceBranchLoader.loadBranchSnapshots(
            for: states,
            gitService: gitService
        )
        let maxActiveOperationCount = await gitService.maxActiveOperationCount

        XCTAssertEqual(snapshots.count, states.count)
        XCTAssertLessThanOrEqual(
            maxActiveOperationCount,
            WorkplaceBranchLoader.maxConcurrentSnapshotLoads
        )
    }

    func test_loaderFallsBackToCurrentBranchAndSkipsMissingLocalDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existingDirectory = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(
            at: existingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existingState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: existingDirectory.path,
            lastError: nil,
            lastSyncedAt: nil
        )
        let missingState = RepositorySyncState(
            workplaceID: existingState.workplaceID,
            repositoryID: UUID(),
            status: .success,
            localPath: root.appendingPathComponent("missing").path,
            lastError: nil,
            lastSyncedAt: nil
        )

        let gitService = WorkplaceBranchLoaderGitServiceSpy(operationDelay: .zero)
        await gitService.removeBranchStatus(for: existingState.localPath)
        await gitService.setCurrentBranch("release/ios", for: existingState.localPath)
        await gitService.setBranches(["main"], for: existingState.localPath)

        let snapshots = await WorkplaceBranchLoader.loadBranchSnapshots(
            for: [existingState, missingState],
            gitService: gitService
        )
        let currentBranchCalls = await gitService.currentBranchCalls

        XCTAssertEqual(snapshots.count, 1)

        let key = RepositoryBranchCacheKey(state: existingState)
        XCTAssertEqual(snapshots[key]?.currentBranch, "release/ios")
        XCTAssertEqual(snapshots[key]?.branches, ["main", "release/ios"])
        XCTAssertEqual(currentBranchCalls, [existingState.localPath])
    }
}
