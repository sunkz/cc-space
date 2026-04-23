import XCTest
@testable import CCSpace

private actor MergeRequestGitServiceStub: GitServicing {
    var defaultBranchInResult: String?
    var defaultBranchForResult: String?
    var currentBranchResult: String?
    var remoteURLResult: String?

    init(
        defaultBranchInResult: String? = "main",
        defaultBranchForResult: String? = nil,
        currentBranchResult: String? = "feature/demo",
        remoteURLResult: String? = "git@code.example.com:team/app.git"
    ) {
        self.defaultBranchInResult = defaultBranchInResult
        self.defaultBranchForResult = defaultBranchForResult
        self.currentBranchResult = currentBranchResult
        self.remoteURLResult = remoteURLResult
    }

    func clone(repositoryURL: String, into directory: String) async throws {}
    func pull(in directory: String) async throws {}
    func push(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { defaultBranchForResult }
    func defaultBranch(in directory: String) async -> String? { defaultBranchInResult }
    func currentBranch(in directory: String) async -> String? { currentBranchResult }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? { nil }
    func branches(in directory: String) async -> [String] { [] }
    func remoteURL(in directory: String) async -> String? { remoteURLResult }
    func checkoutBranch(_ branch: String, in directory: String) async throws {}
    func createLocalBranch(_ branch: String, in directory: String) async throws {}
    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }
    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] { [] }
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome { .merged }
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }
}

final class MergeRequestServiceTests: XCTestCase {
    func test_createURLUsesLocalRemoteAndBranches() async throws {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@fallback.example.com:team/app.git",
            repoName: "app",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: repository.id,
            status: .success,
            localPath: "/tmp/app",
            lastError: nil,
            lastSyncedAt: nil
        )
        let gitService = MergeRequestGitServiceStub()

        let url = try await MergeRequestService.createURL(
            repository: repository,
            syncState: syncState,
            gitService: gitService
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://code.example.com/team/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )
    }

    func test_createURLFallsBackToRepositoryRemoteAndRemoteDefaultBranch() async throws {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "https://github.example.com/team/app.git",
            repoName: "app",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: repository.id,
            status: .success,
            localPath: "/tmp/app",
            lastError: nil,
            lastSyncedAt: nil
        )
        let gitService = MergeRequestGitServiceStub(
            defaultBranchInResult: nil,
            defaultBranchForResult: "main",
            currentBranchResult: "feature/demo",
            remoteURLResult: nil
        )

        let url = try await MergeRequestService.createURL(
            repository: repository,
            syncState: syncState,
            gitService: gitService
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://github.example.com/team/app/compare/main...feature/demo?expand=1"
        )
    }

    func test_createURLUsesSpecifiedTargetBranchWhenProvided() async throws {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@code.example.com:team/app.git",
            repoName: "app",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: repository.id,
            status: .success,
            localPath: "/tmp/app",
            lastError: nil,
            lastSyncedAt: nil
        )
        let gitService = MergeRequestGitServiceStub(
            defaultBranchInResult: "main",
            defaultBranchForResult: nil,
            currentBranchResult: "feature/demo",
            remoteURLResult: "git@code.example.com:team/app.git"
        )

        let url = try await MergeRequestService.createURL(
            repository: repository,
            syncState: syncState,
            gitService: gitService,
            targetBranch: "develop"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://code.example.com/team/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=develop"
        )
    }

    func test_createURLThrowsWhenCurrentBranchMissing() async {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@code.example.com:team/app.git",
            repoName: "app",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: repository.id,
            status: .success,
            localPath: "/tmp/app",
            lastError: nil,
            lastSyncedAt: nil
        )
        let gitService = MergeRequestGitServiceStub(
            defaultBranchInResult: "main",
            defaultBranchForResult: nil,
            currentBranchResult: nil,
            remoteURLResult: "git@code.example.com:team/app.git"
        )

        do {
            _ = try await MergeRequestService.createURL(
                repository: repository,
                syncState: syncState,
                gitService: gitService
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "无法识别当前分支")
        }
    }
}
