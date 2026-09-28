import XCTest
@testable import CCSpace

/// RepositoryWindowContext 的代际号防过期写回测试:
/// 用可控延迟的 GitServicing 桩制造"在途旧任务",验证新请求/取消/早退路径
/// 都能拦下旧一代结果的落笔。
@MainActor
final class RepositoryWindowContextTests: XCTestCase {
    func test_loadBranchContext_snapshotCarriesFieldsAndMetadataSwitch() async throws {
        let stub = WindowContextGitStub()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata: [String: GitBranchMetadata] = [
            "main": GitBranchMetadata(lastCommitDate: date, aheadCount: 2, behindCount: 1, upstreamGone: true, hasUpstream: true)
        ]
        await stub.setBranches(["main", "dev"], for: "/repo")
        await stub.setRemoteTrackingBranches(["origin/main"], for: "/repo")
        await stub.setCurrentBranch("dev", for: "/repo")
        await stub.setDefaultBranch("origin/HEAD", for: "/repo")
        await stub.setBranchMetadata(metadata, for: "/repo")
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()

        let loaded = expectation(description: "首次分支上下文加载完成")
        context.loadBranchContext(directory: "/repo", includeMetadata: true) { snapshot in
            box.branchSnapshots.append(snapshot)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        guard let snapshot = box.branchSnapshots.first else {
            XCTFail("期望分支上下文加载有完成回调")
            return
        }
        XCTAssertEqual(snapshot.branches, ["main", "dev"])
        XCTAssertEqual(snapshot.remoteTrackingBranches, ["origin/main"])
        XCTAssertEqual(snapshot.currentBranch, "dev")
        XCTAssertEqual(snapshot.defaultBranch, "origin/HEAD")
        XCTAssertEqual(snapshot.metadata, metadata)

        let reloaded = expectation(description: "不带 metadata 的二次加载完成")
        context.loadBranchContext(directory: "/repo", includeMetadata: false) { snapshot in
            box.branchSnapshots.append(snapshot)
            reloaded.fulfill()
        }
        await fulfillment(of: [reloaded], timeout: 5.0)
        XCTAssertEqual(box.branchSnapshots.count, 2)
        XCTAssertNil(box.branchSnapshots[1].metadata)
    }

    func test_loadBranchContext_supersededRequestDoesNotWriteBack() async throws {
        let stub = WindowContextGitStub()
        await stub.setCallDelay(nanoseconds: 100_000_000)
        await stub.setBranches(["stale"], for: "/repo-stale")
        await stub.setBranches(["fresh"], for: "/repo-fresh")
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()

        context.loadBranchContext(directory: "/repo-stale", includeMetadata: false) { snapshot in
            box.branchSnapshots.append(snapshot)
        }
        let freshLoaded = expectation(description: "新一代分支上下文加载完成")
        context.loadBranchContext(directory: "/repo-fresh", includeMetadata: false) { snapshot in
            box.branchSnapshots.append(snapshot)
            freshLoaded.fulfill()
        }
        await fulfillment(of: [freshLoaded], timeout: 5.0)
        // 旧任务延迟 100ms,这里再等一段远超延迟的时间:若代际拦截失效必然已落笔。
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(box.branchSnapshots.count, 1)
        XCTAssertEqual(box.branchSnapshots.first?.branches, ["fresh"])
    }

    func test_loadCompareDiff_successCarriesEntriesAndDivergence() async throws {
        let stub = WindowContextGitStub()
        let entries = [GitDiffEntry(filePath: "Sources/a.swift", insertions: 4, deletions: 2, patch: "diff --git a/Sources/a.swift")]
        await stub.setDiffEntries(entries, for: "/repo")
        await stub.setDivergence(GitRefDivergence(baseOnlyCount: 2, headOnlyCount: 7))
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()

        let loaded = expectation(description: "diff 加载完成")
        context.loadCompareDiff(directory: "/repo", base: "main", head: "dev") { outcome in
            box.diffOutcomes.append(outcome)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        guard case let .success(diffEntries, divergence)? = box.diffOutcomes.first else {
            XCTFail("期望 diff 加载成功,实际 outcome 数量: \(box.diffOutcomes.count)")
            return
        }
        XCTAssertEqual(diffEntries, entries)
        XCTAssertEqual(divergence, GitRefDivergence(baseOnlyCount: 2, headOnlyCount: 7))
    }

    func test_loadCompareDiff_failureUsesLocalizedErrorMessage() async throws {
        let stub = WindowContextGitStub()
        await stub.setDiffLocalizedErrorMessage("远端引用不存在", for: "/repo-bad")
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()

        let loaded = expectation(description: "diff 失败加载完成")
        context.loadCompareDiff(directory: "/repo-bad", base: "main", head: "ghost") { outcome in
            box.diffOutcomes.append(outcome)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)

        guard case let .failure(message)? = box.diffOutcomes.first else {
            XCTFail("期望 diff 加载失败并携带文案")
            return
        }
        XCTAssertEqual(message, "远端引用不存在")

        // 静态兜底:非 LocalizedError 经 UserFacingError 加"系统错误："前缀。
        let nsError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "底层读取失败"]
        )
        XCTAssertEqual(RepositoryWindowContext.localizedDiffFailureMessage(nsError), "系统错误：底层读取失败")
    }

    func test_invalidateDiffLoads_blocksStaleDiffWriteBackAndKeepsLaterLoadsWorking() async throws {
        let stub = WindowContextGitStub()
        await stub.setCallDelay(nanoseconds: 100_000_000)
        await stub.setDiffEntries(
            [GitDiffEntry(filePath: "stale.swift", insertions: 1, deletions: 0, patch: "stale patch")],
            for: "/repo-slow"
        )
        await stub.setDiffEntries(
            [GitDiffEntry(filePath: "fresh.swift", insertions: 2, deletions: 0, patch: "fresh patch")],
            for: "/repo-ok"
        )
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()

        context.loadCompareDiff(directory: "/repo-slow", base: "main", head: "dev") { outcome in
            box.diffOutcomes.append(outcome)
        }
        context.invalidateDiffLoads()
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(box.diffOutcomes.isEmpty, "作废后旧任务的迟到写回不得落笔")

        await stub.setCallDelay(nanoseconds: 0)
        let loaded = expectation(description: "作废后的新 diff 加载完成")
        context.loadCompareDiff(directory: "/repo-ok", base: "main", head: "dev") { outcome in
            box.diffOutcomes.append(outcome)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5.0)
        guard case let .success(entries, divergence)? = box.diffOutcomes.first else {
            XCTFail("invalidateDiffLoads 不应影响后续新加载")
            return
        }
        XCTAssertEqual(entries.map(\.filePath), ["fresh.swift"])
        XCTAssertNil(divergence)
    }

    func test_loadCommits_probesExtraCommitAndMissingDirectoryBlocksStaleWriteBack() async throws {
        let stub = WindowContextGitStub()
        let context = RepositoryWindowContext(gitService: stub)
        let box = WindowContextCompletionBox()
        let directory = FileManager.default.temporaryDirectory.path
        let entries = (1...3).map { index in
            GitCommitEntry(hash: "commit-\(index)", subject: "标题 \(index)", author: "tester", date: .distantPast)
        }
        await stub.setCommits(entries, for: directory)

        let fullLoaded = expectation(description: "全量提交加载完成")
        context.loadCommits(directory: directory, limit: 2, rev: "feature/x", unpushedOnly: false) { outcome in
            box.logOutcomes.append(outcome)
            fullLoaded.fulfill()
        }
        await fulfillment(of: [fullLoaded], timeout: 5.0)
        guard case let .success(commits, hasMore) = box.logOutcomes.first, hasMore else {
            XCTFail("期望 hasMore=true 的成功加载")
            return
        }
        XCTAssertEqual(commits.count, 3)
        let recentRequests = await stub.recentCommitRequests
        XCTAssertEqual(recentRequests.count, 1)
        XCTAssertEqual(recentRequests[0].count, 3, "内部应多取一条探测是否有更多")
        XCTAssertEqual(recentRequests[0].rev, "feature/x")

        await stub.setUnpushedCommits(Array(entries.prefix(2)), for: directory)
        let unpushedLoaded = expectation(description: "未推送提交加载完成")
        context.loadCommits(directory: directory, limit: 2, rev: nil, unpushedOnly: true) { outcome in
            box.logOutcomes.append(outcome)
            unpushedLoaded.fulfill()
        }
        await fulfillment(of: [unpushedLoaded], timeout: 5.0)
        guard case let .success(unpushedCommits, unpushedHasMore) = box.logOutcomes[1], unpushedHasMore == false else {
            XCTFail("期望 hasMore=false 的未推送加载")
            return
        }
        XCTAssertEqual(unpushedCommits.count, 2)
        let unpushedRequests = await stub.unpushedCommitRequests
        XCTAssertEqual(unpushedRequests.count, 1)
        XCTAssertEqual(unpushedRequests[0].count, 3)

        // 目录缺失是硬失败;目录探测已移入 Task.detached,结局异步送达,
        // 用等待而非调用点同步断言。入口代际递增须拦下在途旧加载的写回。
        await stub.setCallDelay(nanoseconds: 100_000_000)
        context.loadCommits(directory: directory, limit: 2, rev: nil, unpushedOnly: false) { outcome in
            box.logOutcomes.append(outcome)
        }
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccspace-missing-\(UUID().uuidString)")
            .path
        let missingLoaded = expectation(description: "目录缺失结局送达")
        context.loadCommits(directory: missingDirectory, limit: 2, rev: nil, unpushedOnly: false) { outcome in
            box.logOutcomes.append(outcome)
            missingLoaded.fulfill()
        }
        await fulfillment(of: [missingLoaded], timeout: 5.0)
        XCTAssertEqual(box.logOutcomes.count, 3, "目录缺失前仅有两笔成功结局,被拦下的旧任务不应写回")
        guard case let .directoryMissing(reportedPath)? = box.logOutcomes.last else {
            XCTFail("期望 .directoryMissing 结局")
            return
        }
        XCTAssertEqual(reportedPath, missingDirectory)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(box.logOutcomes.count, 3, "早退递增的代际须拦住在途旧任务的迟到写回")
    }
}

// MARK: - 夹具

@MainActor
private final class WindowContextCompletionBox {
    var branchSnapshots: [RepositoryWindowContext.BranchContextSnapshot] = []
    var diffOutcomes: [RepositoryWindowContext.DiffLoadOutcome] = []
    var logOutcomes: [RepositoryWindowContext.CommitLogLoadOutcome] = []
}

/// GitServicing 桩:仅覆盖 RepositoryWindowContext 用到的通道,
/// 支持按目录配置返回值与统一延迟,用于制造在途旧任务。
private actor WindowContextGitStub: GitServicing {
    struct StubLocalizedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var callDelayNanoseconds: UInt64 = 0
    private var branchesByDirectory: [String: [String]] = [:]
    private var remoteTrackingBranchesByDirectory: [String: [String]] = [:]
    private var currentBranchByDirectory: [String: String] = [:]
    private var defaultBranchByDirectory: [String: String] = [:]
    private var branchMetadataByDirectory: [String: [String: GitBranchMetadata]] = [:]
    private var diffEntriesByDirectory: [String: [GitDiffEntry]] = [:]
    private var diffErrorMessageByDirectory: [String: String] = [:]
    private var divergenceResult: GitRefDivergence?
    private var commitsByDirectory: [String: [GitCommitEntry]] = [:]
    private var unpushedCommitsByDirectory: [String: [GitCommitEntry]] = [:]
    private(set) var recentCommitRequests: [(count: Int, rev: String?)] = []
    private(set) var unpushedCommitRequests: [(count: Int, rev: String?)] = []

    // 协议必需(无默认实现)的成员
    func clone(repositoryURL: String, into directory: String) async throws {}
    func pull(in directory: String) async throws {}
    func push(in directory: String) async throws {}
    func stash(in directory: String) async throws {}
    func stashPop(in directory: String) async throws {}
    func isGitAvailable() async -> Bool { true }
    func defaultBranch(for remoteURL: String) async -> String? { "main" }
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? { nil }
    func remoteURL(in directory: String) async -> String? { nil }
    func checkoutBranch(_ branch: String, in directory: String) async throws {}
    func createLocalBranch(_ branch: String, in directory: String) async throws {}
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome { .merged }
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        await recentCommits(in: directory, count: count, rev: nil)
    }
    func remoteBranches(for remoteURL: String) async -> [String] { [] }

    // RepositoryWindowContext 实际使用的通道
    func branches(in directory: String) async -> [String] {
        await sleepIfDelayed()
        return branchesByDirectory[directory] ?? ["main"]
    }

    func remoteTrackingBranches(in directory: String) async -> [String] {
        remoteTrackingBranchesByDirectory[directory] ?? []
    }

    func currentBranch(in directory: String) async -> String? {
        currentBranchByDirectory[directory] ?? "main"
    }

    func defaultBranch(in directory: String) async -> String? {
        defaultBranchByDirectory[directory] ?? "main"
    }

    func branchMetadata(in directory: String) async -> [String: GitBranchMetadata] {
        branchMetadataByDirectory[directory] ?? [:]
    }

    func diffBranches(base: String, head: String, in directory: String) async throws -> [GitDiffEntry] {
        if let message = diffErrorMessageByDirectory[directory] {
            throw StubLocalizedError(message: message)
        }
        await sleepIfDelayed()
        return diffEntriesByDirectory[directory] ?? []
    }

    func divergence(base: String, head: String, in directory: String) async -> GitRefDivergence? {
        divergenceResult
    }

    func recentCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        recentCommitRequests.append((count: count, rev: rev))
        await sleepIfDelayed()
        return commitsByDirectory[directory] ?? []
    }

    func unpushedCommits(in directory: String, count: Int, rev: String?) async -> [GitCommitEntry] {
        unpushedCommitRequests.append((count: count, rev: rev))
        await sleepIfDelayed()
        return unpushedCommitsByDirectory[directory] ?? []
    }

    // 配置入口
    func setCallDelay(nanoseconds: UInt64) {
        callDelayNanoseconds = nanoseconds
    }

    func setBranches(_ branches: [String], for directory: String) {
        branchesByDirectory[directory] = branches
    }

    func setRemoteTrackingBranches(_ branches: [String], for directory: String) {
        remoteTrackingBranchesByDirectory[directory] = branches
    }

    func setCurrentBranch(_ branch: String, for directory: String) {
        currentBranchByDirectory[directory] = branch
    }

    func setDefaultBranch(_ branch: String, for directory: String) {
        defaultBranchByDirectory[directory] = branch
    }

    func setBranchMetadata(_ metadata: [String: GitBranchMetadata], for directory: String) {
        branchMetadataByDirectory[directory] = metadata
    }

    func setDiffEntries(_ entries: [GitDiffEntry], for directory: String) {
        diffEntriesByDirectory[directory] = entries
    }

    func setDiffLocalizedErrorMessage(_ message: String, for directory: String) {
        diffErrorMessageByDirectory[directory] = message
    }

    func setDivergence(_ divergence: GitRefDivergence?) {
        divergenceResult = divergence
    }

    func setCommits(_ commits: [GitCommitEntry], for directory: String) {
        commitsByDirectory[directory] = commits
    }

    func setUnpushedCommits(_ commits: [GitCommitEntry], for directory: String) {
        unpushedCommitsByDirectory[directory] = commits
    }

    private func sleepIfDelayed() async {
        guard callDelayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: callDelayNanoseconds)
    }
}
