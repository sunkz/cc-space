import XCTest
@testable import CCSpace

final class RepositoryInfoServiceTests: XCTestCase {
    func test_recentCommitsReturnsNilWhenDirectoryMissing() async {
        let service = RepositoryInfoService(gitService: StubGitService())

        let entries = await service.recentCommits(
            localPath: "/nonexistent/\(UUID().uuidString)",
            limit: 10
        )

        XCTAssertNil(entries)
    }

    func test_stashListReturnsNilWhenDirectoryMissing() async {
        let service = RepositoryInfoService(gitService: StubGitService())

        let entries = await service.stashList(localPath: "/nonexistent/\(UUID().uuidString)")

        XCTAssertNil(entries)
    }

    func test_remoteBranchSuggestionsReturnsNilWithoutAnyRemote() async {
        let service = RepositoryInfoService(gitService: StubGitService())

        // 本地目录不存在(remoteURL 查询失败)且无配置地址兜底 → 无法确定远端。
        let branches = await service.remoteBranchSuggestions(
            localPath: "/nonexistent/\(UUID().uuidString)",
            configuredURL: nil
        )

        XCTAssertNil(branches)
    }

    func test_remoteBranchSuggestionsFallsBackToConfiguredURL() async {
        let service = RepositoryInfoService(gitService: StubGitService(
            stubbedRemoteBranches: ["main", "feature/x"]
        ))

        let branches = await service.remoteBranchSuggestions(
            localPath: "/nonexistent/\(UUID().uuidString)",
            configuredURL: "https://example.com/repo.git"
        )

        XCTAssertEqual(branches, ["main", "feature/x"])
    }

    func test_probeRemoteReturnsBranchesAndDefaultBranch() async {
        let service = RepositoryInfoService(gitService: StubGitService(
            stubbedRemoteBranches: ["main"],
            stubbedDefaultBranch: "main"
        ))

        let probe = await service.probeRemote(gitURL: "https://example.com/repo.git")

        XCTAssertEqual(probe.branches, ["main"])
        XCTAssertEqual(probe.defaultBranch, "main")
    }

    /// probeRemote 应走单次探测接口(真实实现一条 `ls-remote --symref` 完成),
    /// 而不是分头的 remoteBranches + defaultBranch 两次查询。
    func test_probeRemoteDelegatesToSingleProbeEndpoint() async {
        let service = RepositoryInfoService(gitService: StubGitService(
            stubbedRemoteBranches: ["should-not-be-used"],
            stubbedDefaultBranch: "should-not-be-used",
            stubbedProbeInfo: (branches: ["main", "dev"], defaultBranch: "main")
        ))

        let probe = await service.probeRemote(gitURL: "https://example.com/repo.git")

        XCTAssertEqual(probe.branches, ["main", "dev"])
        XCTAssertEqual(probe.defaultBranch, "main")
    }
}

/// 只响应远端查询、不启动真实 git 进程的替身;
/// 其余查询交给真实实现时会因目录不存在而自然失败。
/// 用不可变 struct 满足 Sendable(Swift 6 下可变存储属性的 class 不行)。
private struct StubGitService: GitServicing {
    var stubbedRemoteBranches: [String] = []
    var stubbedDefaultBranch: String?
    /// 单次探测接口的桩数据;为 nil 时模拟协议默认实现(回退到分头两次查询)。
    var stubbedProbeInfo: (branches: [String], defaultBranch: String?)?

    func remoteBranches(for remoteURL: String) async -> [String] {
        stubbedRemoteBranches
    }

    func defaultBranch(for remoteURL: String) async -> String? {
        stubbedDefaultBranch
    }

    func probeRemoteInfo(for remoteURL: String) async -> (branches: [String], defaultBranch: String?) {
        stubbedProbeInfo ?? (stubbedRemoteBranches, stubbedDefaultBranch)
    }

    func remoteURL(in directory: String) async -> String? { nil }

    // 其余协议方法仅需可编译;目录不存在时真实实现路径不会被走到。
    func clone(repositoryURL: String, into directory: String) async throws {}
    func pull(in directory: String) async throws {}
    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome {
        GitPullAllBranchesOutcome(currentBranch: nil, currentBranchOutcome: nil, otherBranchOutcomes: [], primaryError: nil)
    }
    func push(in directory: String) async throws {}
    func stash(in directory: String) async throws {}
    func stashPop(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { false }
    func defaultBranch(in directory: String) async -> String? { nil }
    func currentBranch(in directory: String) async -> String? { nil }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? { nil }
    func branches(in directory: String) async -> [String] { [] }
    func checkoutBranch(_ branch: String, in directory: String) async throws {}
    func createLocalBranch(_ branch: String, in directory: String) async throws {}
    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool { false }
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome { .skipped }
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] { [] }
}
