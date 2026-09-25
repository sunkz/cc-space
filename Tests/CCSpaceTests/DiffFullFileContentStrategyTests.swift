import XCTest
@testable import CCSpace

final class DiffFullFileContentStrategyTests: XCTestCase {
    func test_workingDirectorySourceReadsWorkingTree() {
        XCTAssertEqual(
            DiffFullFileContentStrategy.resolve(source: .workingDirectory, currentBranch: "main"),
            .workingTree
        )
    }

    func test_commitSourceReadsCommitBlob() {
        XCTAssertEqual(
            DiffFullFileContentStrategy.resolve(source: .commit(hash: "abc123"), currentBranch: "main"),
            .revision("abc123")
        )
    }

    func test_compareSourceReadsHeadBlobUnlessHeadIsCurrentBranch() {
        XCTAssertEqual(
            DiffFullFileContentStrategy.resolve(
                source: .compare(base: "main", head: "feature"),
                currentBranch: "main"
            ),
            .revision("feature")
        )
        // head 为当前分支时 diff 实为 `git diff <base>`(对比到工作区,含未提交改动),
        // 新侧必须读磁盘;取 blob 会漏掉未提交改动,展示的内容与 diff 对不上。
        XCTAssertEqual(
            DiffFullFileContentStrategy.resolve(
                source: .compare(base: "main", head: "main"),
                currentBranch: "main"
            ),
            .workingTree
        )
    }

    func test_compareSourceWithoutHeadCannotExpand() {
        XCTAssertNil(
            DiffFullFileContentStrategy.resolve(
                source: .compare(base: "main", head: nil),
                currentBranch: "main"
            )
        )
    }

    func test_fileContentSkipsBinaryEntriesWithoutReadingAnything() async {
        let binaryEntry = GitDiffEntry(filePath: "img.png", insertions: -1, deletions: -1, patch: "")
        let service = FullFileContentStubGitService(blob: "should not be read")

        let content = await DiffFullFileContentStrategy.workingTree.fileContent(
            entry: binaryEntry, localPath: NSTemporaryDirectory(), gitService: service
        )

        XCTAssertNil(content)
        XCTAssertEqual(service.blobContentCallCount, 0)
    }

    func test_fileContentReadsBlobThroughGitService() async {
        let entry = GitDiffEntry(filePath: "f.txt", insertions: 1, deletions: 0, patch: "")
        let service = FullFileContentStubGitService(blob: "full text")

        let content = await DiffFullFileContentStrategy.revision("abc123").fileContent(
            entry: entry, localPath: "/repo", gitService: service
        )

        XCTAssertEqual(content, "full text")
        XCTAssertEqual(service.requestedRevision, "abc123")
        XCTAssertEqual(service.requestedPath, "f.txt")
        XCTAssertEqual(service.requestedDirectory, "/repo")
    }

    func test_fileContentReadsWorkingTreeFromDisk() async throws {
        let directory = NSTemporaryDirectory() + "DiffFullFileContentStrategyTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "disk content\n".write(toFile: directory + "/f.txt", atomically: true, encoding: .utf8)

        let entry = GitDiffEntry(filePath: "f.txt", insertions: 1, deletions: 0, patch: "")
        let service = FullFileContentStubGitService()

        let content = await DiffFullFileContentStrategy.workingTree.fileContent(
            entry: entry, localPath: directory, gitService: service
        )

        XCTAssertEqual(content, "disk content\n")
        XCTAssertEqual(service.blobContentCallCount, 0)
    }
}

/// 记录 blobContent 调用参数的替身;需要可变记录,故用 @unchecked Sendable 的 class。
private final class FullFileContentStubGitService: GitServicing, @unchecked Sendable {
    let blob: String?
    private(set) var blobContentCallCount = 0
    private(set) var requestedRevision: String?
    private(set) var requestedPath: String?
    private(set) var requestedDirectory: String?

    init(blob: String? = nil) {
        self.blob = blob
    }

    func blobContent(revision: String, path: String, in directory: String) async -> String? {
        blobContentCallCount += 1
        requestedRevision = revision
        requestedPath = path
        requestedDirectory = directory
        return blob
    }

    // 其余协议方法仅需可编译,不会被走到。
    func clone(repositoryURL: String, into directory: String) async throws {}
    func pull(in directory: String) async throws {}
    func pullAllBranches(in directory: String) async throws -> GitPullAllBranchesOutcome {
        GitPullAllBranchesOutcome(currentBranch: nil, currentBranchOutcome: nil, otherBranchOutcomes: [], primaryError: nil)
    }
    func push(in directory: String) async throws {}
    func stash(in directory: String) async throws {}
    func stashPop(in directory: String) async throws {}
    func fetch(in directory: String) async throws {}
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
    func remoteBranches(for remoteURL: String) async -> [String] { [] }
    func remoteURL(in directory: String) async -> String? { nil }
    func defaultBranch(for remoteURL: String) async -> String? { nil }
}
