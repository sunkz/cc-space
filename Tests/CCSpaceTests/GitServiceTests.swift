import XCTest
@testable import CCSpace

final class GitServiceTests: XCTestCase {
    func test_checkoutBranchSwitchesToExistingLocalBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature/demo"])
        _ = try shell(["git", "-C", repository.path, "checkout", "main"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: repository.path)

        let currentBranch = await service.currentBranch(in: repository.path)
        XCTAssertEqual(currentBranch, "feature/demo")
    }

    func test_checkoutBranchCreatesTrackingBranchFromRemoteWhenLocalBranchMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/demo"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/demo"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "checkout", "main"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: clone.path)

        let currentBranch = await service.currentBranch(in: clone.path)
        let branchesOutput = try shell(["git", "-C", clone.path, "branch", "--list", "feature/demo"])

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertTrue(branchesOutput.contains("feature/demo"))
    }

    func test_checkoutBranchFetchesRemoteBranchWhenOriginReferenceIsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])

        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/demo"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("FEATURE.md").path,
            contents: Data("remote branch".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "FEATURE.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "feature"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/demo"])

        let staleRemoteBranch = try shell(["git", "-C", clone.path, "branch", "-r", "--list", "origin/feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(staleRemoteBranch.isEmpty)

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: clone.path)

        let currentBranch = await service.currentBranch(in: clone.path)
        let localHead = try shell(["git", "-C", clone.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFeatureHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainHead = try shell(["git", "-C", clone.path, "rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertEqual(localHead, remoteFeatureHead)
        XCTAssertNotEqual(localHead, mainHead)
    }

    func test_checkoutBranchCreatesLocalBranchFromCurrentHeadWhenRemoteBranchMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: repository.path)

        let currentBranch = await service.currentBranch(in: repository.path)
        let featureHead = try shell(["git", "-C", repository.path, "rev-parse", "feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainHead = try shell(["git", "-C", repository.path, "rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertEqual(featureHead, mainHead)
    }

    func test_defaultBranchUsesLocalOriginHeadReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])

        let service = GitService()
        let defaultBranch = await service.defaultBranch(in: clone.path)

        XCTAssertEqual(defaultBranch, "main")
    }

    func test_pushSetsUpstreamWhenCurrentBranchHasNoTrackingBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])

        let service = GitService()
        try await service.push(in: source.path)

        let upstream = try shell([
            "git", "-C", source.path,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localHead = try shell(["git", "-C", source.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(upstream, "origin/main")
        XCTAssertEqual(remoteHead, localHead)
    }

    func test_pushUsesExistingTrackingBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", clone.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: clone.appendingPathComponent("README.md").path,
            contents: Data("updated".utf8)
        )
        _ = try shell(["git", "-C", clone.path, "add", "README.md"])
        _ = try shell(["git", "-C", clone.path, "commit", "-m", "update"])

        let service = GitService()
        try await service.push(in: clone.path)

        let remoteHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localHead = try shell(["git", "-C", clone.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(remoteHead, localHead)
    }

    func test_stashIncludesUntrackedFilesAndRestoresThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        try Data("changed".utf8).write(to: repository.appendingPathComponent("README.md"))
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("notes.txt").path,
            contents: Data("untracked".utf8)
        )

        let service = GitService()
        try await service.stash(in: repository.path)

        let cleanStatus = try shell(["git", "-C", repository.path, "status", "--porcelain"])
        XCTAssertTrue(cleanStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("notes.txt").path))

        try await service.stashPop(in: repository.path)

        let restoredStatus = try shell(["git", "-C", repository.path, "status", "--porcelain"])
        XCTAssertTrue(restoredStatus.contains("M README.md"))
        XCTAssertTrue(restoredStatus.contains("?? notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("notes.txt").path))
    }

    func test_recentCommitsIncludesChangeStats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])

        // 首次提交:新增 2 文件。
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("a.txt").path,
            contents: Data("aaaa\n".utf8)
        )
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("b.txt").path,
            contents: Data("bbbb\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "a.txt", "b.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "add two files"])

        // 第二次提交:修改 a.txt(删 1 行 + 增 2 行)+ 新增 c.txt。
        try Data("a\naa\naa\n".utf8).write(to: repository.appendingPathComponent("a.txt"))
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("c.txt").path,
            contents: Data("cc\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "a.txt", "c.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "modify a and add c"])

        let service = GitService()
        let commits = await service.recentCommits(in: repository.path, count: 10)

        XCTAssertEqual(commits.count, 2)
        // 最新提交排在最前。
        let latest = commits[0]
        XCTAssertEqual(latest.subject, "modify a and add c")
        XCTAssertEqual(latest.filesChanged, 2)  // a.txt + c.txt
        XCTAssertNotNil(latest.insertions)
        XCTAssertNotNil(latest.deletions)
        XCTAssertTrue(latest.hasStats)

        // 首次提交新增 2 文件,无删除。
        let first = commits[1]
        XCTAssertEqual(first.subject, "add two files")
        XCTAssertEqual(first.filesChanged, 2)
        XCTAssertEqual(first.insertions, 2)
        XCTAssertEqual(first.deletions, 0)
    }

    func test_diffWorkingDirectoryShowsUncommittedChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("a.txt").path,
            contents: Data("line1\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "a.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        // 制造未提交改动:修改 a.txt(已跟踪)+ 新增 b.txt(untracked,未 add)。
        try Data("line1\nline2\n".utf8).write(to: repository.appendingPathComponent("a.txt"))
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("b.txt").path,
            contents: Data("new\n".utf8)
        )

        let service = GitService()
        let diffs = await service.diffWorkingDirectory(in: repository.path)

        // 两种改动都应展示:已跟踪文件的修改 + untracked 新文件。
        XCTAssertEqual(diffs.count, 2)
        let paths = Set(diffs.map(\.filePath))
        XCTAssertTrue(paths.contains("a.txt"))
        XCTAssertTrue(paths.contains("b.txt"))

        // a.txt 新增 1 行(无删除),b.txt 是 untracked 新文件。
        let aDiff = diffs.first { $0.filePath == "a.txt" }
        XCTAssertEqual(aDiff?.insertions, 1)
        let bDiff = diffs.first { $0.filePath == "b.txt" }
        XCTAssertEqual(bDiff?.changeType, .added)
        XCTAssertEqual(bDiff?.insertions, 1)
    }

    func test_diffCommitShowsCommitChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("init.txt").path,
            contents: Data("init\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "init.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "first"])

        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("feature\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "second"])

        let service = GitService()
        let commits = await service.recentCommits(in: repository.path, count: 5)
        let secondCommit = commits[0]
        let diffs = await service.diffCommit(hash: secondCommit.hash, in: repository.path)

        // 第二次 commit 只新增 feature.txt。
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.filePath, "feature.txt")
        XCTAssertEqual(diffs.first?.changeType, .added)
        XCTAssertEqual(diffs.first?.insertions, 1)
    }

    func test_blobContentReturnsFileContentAtRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("init.txt").path,
            contents: Data("init\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "init.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "first"])

        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("feature line\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "second"])

        let service = GitService()
        let commits = await service.recentCommits(in: repository.path, count: 5)
        let secondCommit = commits[0]

        let content = await service.blobContent(
            revision: secondCommit.hash, path: "feature.txt", in: repository.path
        )
        XCTAssertEqual(content, "feature line\n")

        // 路径在该版本不存在(如后删除的文件)时返回 nil,按不展开处理。
        let missing = await service.blobContent(
            revision: secondCommit.hash, path: "no-such-file.txt", in: repository.path
        )
        XCTAssertNil(missing)
    }

    func test_diffCommitShowsMergeChangesWithPatchContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("base.txt").path,
            contents: Data("base\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "base.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        // main 上新增改动,再合并进 feature,制造 merge commit。
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature/demo"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("feature\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "on feature"])
        _ = try shell(["git", "-C", repository.path, "checkout", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("merged.txt").path,
            contents: Data("merged\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "merged.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "on main"])
        _ = try shell(["git", "-C", repository.path, "checkout", "feature/demo"])
        _ = try shell(["git", "-C", repository.path, "merge", "main"])

        let service = GitService()
        let commits = await service.recentCommits(in: repository.path, count: 5)
        let mergeCommit = commits.first { $0.subject.contains("Merge") }
        XCTAssertNotNil(mergeCommit)
        let diffs = await service.diffCommit(hash: mergeCommit!.hash, in: repository.path)

        // merge commit 应按第一父提交展示改动:文件列表与 patch 内容都非空。
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.filePath, "merged.txt")
        XCTAssertFalse(diffs.first?.patch.isEmpty ?? true)
        XCTAssertTrue(diffs.first?.patch.contains("+merged") ?? false)
    }

    func test_diffBranchesShowsChangesFromBaseToHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("base.txt").path,
            contents: Data("base\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "base.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        // 从 main 拉出 feature 分支,在其上新增文件,代表"当前分支相对 main 的改动"。
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("feature\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "add feature"])

        let service = GitService()
        let diffs = await service.diffBranches(base: "main", head: "feature", in: repository.path)

        // feature 相对 main 多出 feature.txt 一个文件。
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.filePath, "feature.txt")
        XCTAssertEqual(diffs.first?.changeType, .added)
        XCTAssertEqual(diffs.first?.insertions, 1)
    }

    func test_diffBranchesWithHeadAsCurrentBranchIncludesUncommittedChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("base.txt").path,
            contents: Data("base\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "base.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        // 与远端同名的本地分支场景:无新提交,只有工作区未提交的已跟踪文件改动。
        // (git diff <base> 的固有边界:未跟踪文件不在其中,查看全部未提交改动用"查看改动"。)
        _ = try shell(["git", "-C", repository.path, "branch", "remote-main", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("base.txt").path,
            contents: Data("base\nmodified\n".utf8)
        )

        let service = GitService()

        // head 为当前分支:走 base → 工作区,包含未提交改动。
        let againstWorkingTree = await service.diffBranches(
            base: "remote-main",
            head: "main",
            in: repository.path
        )
        XCTAssertEqual(againstWorkingTree.map(\.filePath), ["base.txt"])

        // head 非当前分支:仍按提交对比,不含工作区改动。
        let betweenBranches = await service.diffBranches(
            base: "main",
            head: "remote-main",
            in: repository.path
        )
        XCTAssertTrue(betweenBranches.isEmpty)
    }

    func test_diffBranchesPreservesNonASCIIFilePaths() async throws {
        // 回归:中文等非 ASCII 路径在 git 默认 `core.quotepath=true` 下会被转义成八进制
        // (如 `\346\212...`),导致 diff 查看器显示乱码。应用需以 UTF-8 原样输出路径。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("init\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("技术文档.md").path,
            contents: Data("内容\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "技术文档.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "add doc"])

        let service = GitService()
        let diffs = await service.diffBranches(base: "main", head: "feature", in: repository.path)

        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.filePath, "技术文档.md")
        // patch header 里也应包含 UTF-8 路径,而非八进制转义。
        XCTAssertFalse(diffs.first?.patch.contains("\\346") ?? true)
    }

    func test_diffBranchesReturnsEmptyWhenBranchesAreIdentical() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("a.txt").path,
            contents: Data("a\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "a.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        // 建一个指向同一 commit 的分支,两分支无差异。
        _ = try shell(["git", "-C", repository.path, "branch", "feature"])

        let service = GitService()
        let diffs = await service.diffBranches(base: "main", head: "feature", in: repository.path)

        XCTAssertTrue(diffs.isEmpty)
    }

    func test_gitProcessRunnerReportsTimeoutWithSafeCommandDescription() async throws {        do {
            _ = try await GitProcessRunner().run(
                arguments: [
                    "-c",
                    "alias.ccspace-sleep=!exec sleep 2",
                    "ccspace-sleep",
                ],
                captureStdout: true,
                captureStderr: true,
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch let error as GitProcessExecutionError {
            XCTAssertTrue(error.localizedDescription.contains("操作超时"))
            XCTAssertTrue(error.localizedDescription.contains("git -c"))
        }
    }

    func test_redactCredentialsRedactsUserPasswordAndTokenOnlyURLs() {
        // user:pass 形式
        XCTAssertEqual(
            GitServiceError.redactCredentials(in: "fatal: auth failed for https://oauth2:t0k3n-pass@git.example.com/o/r.git"),
            "fatal: auth failed for https://redacted@git.example.com/o/r.git"
        )
        // 用户名即 token(无冒号)形式
        XCTAssertEqual(
            GitServiceError.redactCredentials(in: "remote: https://ghp_AbCd1234@github.com/o/r.git denied"),
            "remote: https://redacted@github.com/o/r.git denied"
        )
        // 无凭据的普通 URL 不受影响
        XCTAssertEqual(
            GitServiceError.redactCredentials(in: "cloning https://github.com/o/r.git"),
            "cloning https://github.com/o/r.git"
        )
        // 密码段含斜杠(base64/URL 风格密钥):仍须整体脱敏
        XCTAssertEqual(
            GitServiceError.redactCredentials(in: "fatal: auth failed for https://user:b64/to/ken@host.example.com/o/r.git"),
            "fatal: auth failed for https://redacted@host.example.com/o/r.git"
        )
        // 路径中带 @ 但无 userinfo:不得误伤
        XCTAssertEqual(
            GitServiceError.redactCredentials(in: "https://example.com/a@b/c.txt"),
            "https://example.com/a@b/c.txt"
        )
        // 多处出现全部脱敏
        let twice = GitServiceError.redactCredentials(in: "a https://tok@x.com/y and https://u:p@z.com/w b")
        XCTAssertFalse(twice.contains("tok"))
        XCTAssertFalse(twice.contains("u:p"))
        XCTAssertEqual(twice, "a https://redacted@x.com/y and https://redacted@z.com/w b")
    }

    func test_unpushedCommitsReturnsOnlyCommitsAheadOfUpstream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", clone.path, "config", "user.name", "test"])

        let service = GitService()

        // 刚克隆完:与上游一致,无未推送提交。
        let beforeCommits = await service.unpushedCommits(in: clone.path, count: 10)
        XCTAssertTrue(beforeCommits.isEmpty)

        // 本地新增两次提交,均未推送。
        FileManager.default.createFile(
            atPath: clone.appendingPathComponent("a.txt").path,
            contents: Data("a\n".utf8)
        )
        _ = try shell(["git", "-C", clone.path, "add", "a.txt"])
        _ = try shell(["git", "-C", clone.path, "commit", "-m", "local one"])
        FileManager.default.createFile(
            atPath: clone.appendingPathComponent("b.txt").path,
            contents: Data("b\n".utf8)
        )
        _ = try shell(["git", "-C", clone.path, "add", "b.txt"])
        _ = try shell(["git", "-C", clone.path, "commit", "-m", "local two"])

        let ahead = await service.unpushedCommits(in: clone.path, count: 10)
        XCTAssertEqual(ahead.map(\.subject), ["local two", "local one"])

        // 推送后恢复为空。
        try await service.push(in: clone.path)
        let afterPush = await service.unpushedCommits(in: clone.path, count: 10)
        XCTAssertTrue(afterPush.isEmpty)
    }

    func test_stashListPushPopAndDropRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        let service = GitService()
        let emptyList = await service.stashList(in: repository.path)
        XCTAssertTrue(emptyList.isEmpty)

        // 第一条 Stash:修改 README。
        try Data("changed".utf8).write(to: repository.appendingPathComponent("README.md"))
        try await service.stashPush(in: repository.path, message: "CCSpace manual stash first")

        // 第二条 Stash:新增 untracked 文件。
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("notes.txt").path,
            contents: Data("untracked".utf8)
        )
        try await service.stashPush(in: repository.path, message: "CCSpace manual stash second")

        // git 会为 stash subject 加 "On <branch>: " 前缀。
        let entries = await service.stashList(in: repository.path)
        XCTAssertEqual(entries.count, 2)
        // stash@{0} 是最新的一条。
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].message, "On main: CCSpace manual stash second")
        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].message, "On main: CCSpace manual stash first")

        // pop stash@{1}:恢复 README 修改,列表只剩一条。
        try await service.popStash(at: 1, in: repository.path)
        let restoredStatus = try shell(["git", "-C", repository.path, "status", "--porcelain"])
        XCTAssertTrue(restoredStatus.contains("M README.md"))
        let afterPop = await service.stashList(in: repository.path)
        XCTAssertEqual(afterPop.count, 1)
        XCTAssertEqual(afterPop[0].message, "On main: CCSpace manual stash second")

        // drop stash@{0}:列表清空。
        try await service.dropStash(at: 0, in: repository.path)
        let afterDrop = await service.stashList(in: repository.path)
        XCTAssertTrue(afterDrop.isEmpty)
    }

    func test_remoteBranchesReturnsBareBranchNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", source.path, "branch", "feature/demo"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/demo"])

        let service = GitService()
        let branches = await service.remoteBranches(for: bareRemote.path)

        // 返回去掉 refs/heads/ 前缀的裸分支名。
        XCTAssertEqual(Set(branches), ["main", "feature/demo"])
    }

    func test_discardChangesRestoresModifiedTrackedFile() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "dir/a.txt", content: "hello")
        let filePath = repository.appendingPathComponent("dir/a.txt")
        try Data("changed".utf8).write(to: filePath)

        let service = GitService()
        try await service.discardChanges(filePath: "dir/a.txt", in: repository.path)

        XCTAssertEqual(try String(contentsOf: filePath, encoding: .utf8), "hello")
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_discardChangesRestoresDeletedTrackedFile() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")
        try FileManager.default.removeItem(at: repository.appendingPathComponent("a.txt"))

        let service = GitService()
        try await service.discardChanges(filePath: "a.txt", in: repository.path)

        let restored = try String(contentsOf: repository.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(restored, "hello")
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_discardChangesRemovesUntrackedFile() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")
        let untrackedPath = repository.appendingPathComponent("notes.txt")
        try Data("scratch".utf8).write(to: untrackedPath)

        let service = GitService()
        try await service.discardChanges(filePath: "notes.txt", in: repository.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: untrackedPath.path))
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_discardChangesRemovesStagedNewFile() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")
        let stagedPath = repository.appendingPathComponent("new.txt")
        try Data("staged".utf8).write(to: stagedPath)
        _ = try shell(["git", "-C", repository.path, "add", "new.txt"])

        let service = GitService()
        try await service.discardChanges(filePath: "new.txt", in: repository.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath.path))
        // 暂存区中的条目也要一并清掉。
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_discardChangesRejectsInvalidFilePath() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")

        let service = GitService()
        do {
            try await service.discardChanges(filePath: "../escape.txt", in: repository.path)
            XCTFail("包含 .. 的路径应被拒绝")
        } catch {
            // 期望抛错,断言仓库状态未被破坏。
            XCTAssertEqual(try workingTreeStatus(in: repository), "")
        }
    }

    func test_commitAllChangesCommitsModifiedAndUntrackedFiles() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")
        try Data("world".utf8).write(to: repository.appendingPathComponent("a.txt"))
        try Data("scratch".utf8).write(to: repository.appendingPathComponent("notes.txt"))

        let service = GitService()
        try await service.commitAllChanges(message: "  update a and add notes  ", in: repository.path)

        // 提交信息首尾空白被裁掉;已修改与 untracked 文件都入库,工作树干净。
        XCTAssertEqual(
            try shell(["git", "-C", repository.path, "log", "-1", "--pretty=%s"]),
            "update a and add notes\n"
        )
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_commitAllChangesInRepositoryWithoutCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")
        _ = try shell(["git", "init", "-b", "main", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        try Data("first".utf8).write(to: repository.appendingPathComponent("a.txt"))

        let service = GitService()
        try await service.commitAllChanges(message: "initial", in: repository.path)

        XCTAssertEqual(
            try shell(["git", "-C", repository.path, "log", "-1", "--pretty=%s"]),
            "initial\n"
        )
        XCTAssertEqual(try workingTreeStatus(in: repository), "")
    }

    func test_commitAllChangesRejectsEmptyMessage() async throws {
        let repository = try makeRepositoryWithCommittedFile(named: "a.txt", content: "hello")
        try Data("world".utf8).write(to: repository.appendingPathComponent("a.txt"))

        let service = GitService()
        do {
            try await service.commitAllChanges(message: "   ", in: repository.path)
            XCTFail("空白提交信息应被拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription, "提交信息不能为空")
            // 校验发生在执行 git 之前:改动保留且未被暂存。
            XCTAssertEqual(try shell(["git", "-C", repository.path, "diff", "--cached", "--name-only"]), "")
        }
    }

    /// 建一个含单次提交(单文件)的本地仓库,返回仓库目录。
    private func makeRepositoryWithCommittedFile(named name: String, content: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")
        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        let filePath = repository.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: filePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: filePath)
        _ = try shell(["git", "-C", repository.path, "add", name])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        return repository
    }

    /// `git status --porcelain` 输出(去尾部换行),空字符串表示工作树干净。
    private func workingTreeStatus(in repository: URL) throws -> String {
        try shell(["git", "-C", repository.path, "status", "--porcelain"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_sanitizedStderr_removesOpenSSHAdvisoryLines() {
        let stderr = """
        ** WARNING: connection is not using a post-quantum key exchange algorithm.
        ** This session may be vulnerable to "store now, decrypt later" attacks.
        ** The server may need to be upgraded. See https://openssh.com/pq.html
        fatal: Need to specify how to reconcile divergent branches.
        """

        XCTAssertEqual(
            GitServiceError.sanitizedStderr(stderr),
            "fatal: Need to specify how to reconcile divergent branches."
        )
        XCTAssertEqual(GitServiceError.sanitizedStderr(""), "")
        XCTAssertEqual(GitServiceError.sanitizedStderr("fatal: bad object"), "fatal: bad object")
    }

    func test_errorMessage_divergentBranchesIsLocalized() {
        let error = GitServiceError.commandFailed(
            exitCode: 128,
            stderr: "fatal: Need to specify how to reconcile divergent branches."
        )
        XCTAssertTrue(error.localizedDescription.contains("分叉"))
    }

    // MARK: - 删除本地分支

    /// 构造带一次提交的 main 与指定分支的仓库;`mergeIntoCurrent` 控制分支是否已合并。
    private func makeBranchRepository(mergedIntoCurrent: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature/demo"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "feature"])
        if mergedIntoCurrent {
            _ = try shell(["git", "-C", repository.path, "checkout", "main"])
            _ = try shell(["git", "-C", repository.path, "merge", "--no-edit", "feature/demo"])
        } else {
            _ = try shell(["git", "-C", repository.path, "checkout", "main"])
        }
        return repository
    }

    private func localBranchExists(_ branch: String, in repository: URL) throws -> Bool {
        let output = try shell(["git", "-C", repository.path, "branch", "--list", branch])
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func test_deleteLocalBranchRemovesMergedBranch() async throws {
        let repository = try makeBranchRepository(mergedIntoCurrent: true)
        let service = GitService()

        try await service.deleteLocalBranch("feature/demo", in: repository.path)

        XCTAssertFalse(try localBranchExists("feature/demo", in: repository))
    }

    /// 含未合并提交的分支在确认删除后应自动回退强制删除,而不是把 git 报错抛给用户。
    func test_deleteLocalBranchFallsBackToForceForUnmergedBranch() async throws {
        let repository = try makeBranchRepository(mergedIntoCurrent: false)
        let service = GitService()

        try await service.deleteLocalBranch("feature/demo", in: repository.path)

        XCTAssertFalse(try localBranchExists("feature/demo", in: repository))
    }

    func test_deleteLocalBranchRefusesCurrentBranchWithLocalizedMessage() async throws {
        let repository = try makeBranchRepository(mergedIntoCurrent: true)
        let service = GitService()

        do {
            try await service.deleteLocalBranch("main", in: repository.path)
            XCTFail("删除当前所在分支应当失败")
        } catch let error as GitServiceError {
            XCTAssertTrue(
                error.localizedDescription.contains("检出"),
                "当前分支删除报错应本地化：\(error.localizedDescription)"
            )
        }
        XCTAssertTrue(try localBranchExists("main", in: repository))
    }

    // MARK: - 删除远端分支

    /// 构造 bare 远端 + 克隆仓库:远端有 main 与 feature/to-delete 两个分支。
    private func makeRemoteBranchRepository() throws -> (source: URL, clone: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/to-delete"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "feature"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/to-delete"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])

        return (source: source, clone: clone)
    }

    private func remoteBranchExists(_ branch: String, on source: URL) throws -> Bool {
        let output = try shell(["git", "-C", source.path, "ls-remote", "--heads", "origin", branch])
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func test_deleteRemoteBranchRemovesBranchOnRemote() async throws {
        let (source, clone) = try makeRemoteBranchRepository()
        let service = GitService()

        try await service.deleteRemoteBranch("feature/to-delete", in: clone.path)

        XCTAssertFalse(try remoteBranchExists("feature/to-delete", on: source))
        XCTAssertTrue(try remoteBranchExists("main", on: source))
    }

    func test_deleteRemoteBranchThrowsWithLocalizedMessageForMissingBranch() async throws {
        let (source, clone) = try makeRemoteBranchRepository()
        let service = GitService()

        do {
            try await service.deleteRemoteBranch("feature/missing", in: clone.path)
            XCTFail("删除不存在的远端分支应当失败")
        } catch let error as GitServiceError {
            XCTAssertTrue(
                error.localizedDescription.contains("远端不存在该分支"),
                "远端分支缺失的报错应本地化：\(error.localizedDescription)"
            )
        }
        XCTAssertTrue(try remoteBranchExists("feature/to-delete", on: source))
    }

    // MARK: - 命令输出解码

    func test_decodedOutputKeepsValidUTF8() {
        XCTAssertEqual(GitService.decodedOutput(Data("fatal: bad object".utf8)), "fatal: bad object")
        XCTAssertEqual(GitService.decodedOutput(Data("分支 main".utf8)), "分支 main")
    }

    /// 非 UTF-8 的文件名会让整段输出解码失败;降级为有损解码,保住可读部分而不是变成空串。
    func test_decodedOutputFallsBackToLossyDecodingForInvalidUTF8() {
        var data = Data("fatal: path '".utf8)
        data.append(contentsOf: [0xFF, 0xFE])   // 非法 UTF-8 序列
        data.append(contentsOf: [0x27])          // 单引号

        let decoded = GitService.decodedOutput(data)

        XCTAssertFalse(decoded.isEmpty, "解码失败不能退化成空串，否则真实报错原因会丢失")
        XCTAssertTrue(decoded.hasPrefix("fatal: path '"), "可读部分应被保留：\(decoded)")
    }

    // MARK: - 丢弃改动的路径校验

    func test_isSafeRepositoryRelativePathAcceptsOrdinaryPaths() {
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath("Sources/App.swift"))
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath(".hidden"))
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath("a/b/c/d.swift"))
    }

    /// 这些是合法文件名,此前用 contains("..") 子串判断会被误拒。
    func test_isSafeRepositoryRelativePathAcceptsNamesContainingDoubleDot() {
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath("file..txt"))
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath("a..b.swift"))
        XCTAssertTrue(GitService.isSafeRepositoryRelativePath("dir../file.txt"))
    }

    func test_isSafeRepositoryRelativePathRejectsTraversalAndAbsolutePaths() {
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath(".."))
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath("../evil"))
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath("a/../../evil"))
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath("a/.."))
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath("/etc/passwd"))
    }

    func test_isSafeRepositoryRelativePathRejectsEmpty() {
        XCTAssertFalse(GitService.isSafeRepositoryRelativePath(""))
    }

    // MARK: - parseSymrefLsRemote(`ls-remote --symref` 单次探测解析)

    func test_parseSymrefLsRemoteExtractsBranchesAndDefaultBranch() {
        let output = """
        ref: refs/heads/main\tHEAD
        abc1234567890\tHEAD
        abc1234567890\trefs/heads/main
        def4567890123\trefs/heads/feature/x
        789abc0123456\trefs/tags/v1.0.0
        """
        let parsed = GitService.parseSymrefLsRemote(output: output)

        XCTAssertEqual(parsed.branches, ["main", "feature/x"])
        XCTAssertEqual(parsed.defaultBranch, "main")
    }

    func test_parseSymrefLsRemoteWithoutSymrefLineReturnsNilDefaultBranch() {
        let output = """
        abc1234567890\trefs/heads/trunk
        def4567890123\trefs/heads/dev
        """
        let parsed = GitService.parseSymrefLsRemote(output: output)

        XCTAssertEqual(parsed.branches, ["trunk", "dev"])
        XCTAssertNil(parsed.defaultBranch)
    }

    func test_parseSymrefLsRemoteIgnoresMalformedAndEmptyLines() {
        let output = "\n\n  \nabc123\tnot-a-ref-line\nabc123\trefs/heads/ok\textra\n"
        let parsed = GitService.parseSymrefLsRemote(output: output)

        XCTAssertEqual(parsed.branches, [])
        XCTAssertNil(parsed.defaultBranch)
    }

    func test_parseSymrefLsRemoteIgnoresNonHeadSymrefAndEmptyTargets() {
        // 符号引用不指向 refs/heads/(如指向 tags)或目标为空时,不产出默认分支。
        let output = "ref: refs/tags/v1\tHEAD\nabc1234567890\trefs/heads/main"
        let parsed = GitService.parseSymrefLsRemote(output: output)

        XCTAssertEqual(parsed.branches, ["main"])
        XCTAssertNil(parsed.defaultBranch)
    }

    func test_branchSnapshotDetectsMergeConflictInterruptedOperationAndAbortClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("conflict.txt").path,
            contents: Data("base\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "conflict.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("conflict.txt").path,
            contents: Data("feature side\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "commit", "-am", "feature change"])
        _ = try shell(["git", "-C", repository.path, "checkout", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("conflict.txt").path,
            contents: Data("main side\n".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "commit", "-am", "main change"])

        // merge 预期以冲突失败退出(非 0),忽略返回码只求进入冲突态。
        _ = try? shell(["git", "-C", repository.path, "merge", "feature"])

        let service = GitService()
        let snapshotResult = await service.branchSnapshotInfo(in: repository.path)
        let snapshot = try XCTUnwrap(snapshotResult)

        XCTAssertTrue(snapshot.status.hasConflicts)
        XCTAssertEqual(snapshot.status.unmergedPaths, ["conflict.txt"])
        XCTAssertEqual(snapshot.status.interruptedOperation, .merge)

        let aborted = try await service.abortInterruptedOperation(in: repository.path)
        XCTAssertEqual(aborted, .merge)

        let afterAbortResult = await service.branchSnapshotInfo(in: repository.path)
        let afterAbort = try XCTUnwrap(afterAbortResult)
        XCTAssertFalse(afterAbort.status.hasConflicts)
        XCTAssertNil(afterAbort.status.interruptedOperation)

        // 已无进行中操作时再中止必须明确报错,而不是静默成功。
        await XCTAssertThrowsErrorAsync(GitServiceError.self) {
            _ = try await service.abortInterruptedOperation(in: repository.path)
        }
    }

    func test_recentAndUnpushedCommitsQuerySpecificBranchRev() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "base commit"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])

        // feature 分支:从 base 切出,只有 feature 提交,且无上游。
        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/only"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("feature.txt").path,
            contents: Data("f".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "feature only commit"])
        _ = try shell(["git", "-C", source.path, "checkout", "main"])

        // main:一个未推送提交(领先 origin/main)。
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("main.txt").path,
            contents: Data("m".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "main.txt"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "main ahead commit"])

        let service = GitService()

        let featureCommits = await service.recentCommits(in: source.path, count: 10, rev: "feature/only")
        let featureSubjects = featureCommits.map(\.subject)
        XCTAssertEqual(featureSubjects, ["feature only commit", "base commit"])

        let mainCommits = await service.recentCommits(in: source.path, count: 10, rev: "main")
        XCTAssertEqual(mainCommits.map(\.subject), ["main ahead commit", "base commit"])

        // origin/main 仍停在 base:验证 rev 支持远端跟踪引用。
        let originMainCommits = await service.recentCommits(in: source.path, count: 10, rev: "origin/main")
        XCTAssertEqual(originMainCommits.map(\.subject), ["base commit"])

        // 未推送:main 有 1 个;feature 无上游 → 空。
        let mainUnpushed = await service.unpushedCommits(in: source.path, count: 10, rev: "main")
        XCTAssertEqual(mainUnpushed.map(\.subject), ["main ahead commit"])
        let featureUnpushed = await service.unpushedCommits(in: source.path, count: 10, rev: "feature/only")
        XCTAssertTrue(featureUnpushed.isEmpty)
    }

    func test_branchMetadataReportsAheadBehindAndDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let worker = root.appendingPathComponent("worker")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "base"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        // 显式指向 main:裸仓默认 HEAD 仍是 master,clone 端能否回退猜分支随 git 版本而异,
        // 不设置会导致 worker 的 push 落到 master、origin/main 不前进(CI 上已翻车)。
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])

        // main:本地领先 1;worker 推一条让本地再落后 1。
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("local.txt").path,
            contents: Data("l".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "local.txt"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "local ahead"])
        _ = try shell(["git", "clone", bareRemote.path, worker.path])
        _ = try shell(["git", "-C", worker.path, "config", "user.email", "w@example.com"])
        _ = try shell(["git", "-C", worker.path, "config", "user.name", "w"])
        FileManager.default.createFile(
            atPath: worker.appendingPathComponent("remote.txt").path,
            contents: Data("r".utf8)
        )
        _ = try shell(["git", "-C", worker.path, "add", "remote.txt"])
        _ = try shell(["git", "-C", worker.path, "commit", "-m", "remote ahead"])
        _ = try shell(["git", "-C", worker.path, "push"])
        _ = try shell(["git", "-C", source.path, "fetch", "origin"])

        // 无上游分支。
        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/no-upstream"])

        let service = GitService()
        let metadata = await service.branchMetadata(in: source.path)

        XCTAssertEqual(metadata["main"]?.aheadCount, 1)
        XCTAssertEqual(metadata["main"]?.behindCount, 1)
        XCTAssertEqual(metadata["main"]?.hasUpstream, true)
        XCTAssertNotNil(metadata["main"]?.lastCommitDate)
        XCTAssertEqual(metadata["feature/no-upstream"]?.aheadCount, 0)
        XCTAssertEqual(metadata["feature/no-upstream"]?.behindCount, 0)
        XCTAssertEqual(metadata["feature/no-upstream"]?.hasUpstream, false)
        XCTAssertNotNil(metadata["feature/no-upstream"]?.lastCommitDate)

        // 分歧统计:origin/main 独有 worker 的提交,main 独有本地提交。
        let divergenceResult = await service.divergence(base: "origin/main", head: "main", in: source.path)
        let divergence = try XCTUnwrap(divergenceResult)
        XCTAssertEqual(divergence.baseOnlyCount, 1)
        XCTAssertEqual(divergence.headOnlyCount, 1)
        // 同一 ref 无分歧。
        let sameResult = await service.divergence(base: "main", head: "main", in: source.path)
        let same = try XCTUnwrap(sameResult)
        XCTAssertEqual(same.baseOnlyCount, 0)
        XCTAssertEqual(same.headOnlyCount, 0)
        // 非法 ref 返回 nil 而非崩溃。
        let invalid = await service.divergence(base: "no/such-ref", head: "main", in: source.path)
        XCTAssertNil(invalid)
    }

    func test_commitDetailAndCreateBranchFromRev() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "base commit"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("feature.txt").path,
            contents: Data("f".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "feature commit", "-m", "body line one"])
        let c2Hash = try shell(["git", "-C", repository.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("later.txt").path,
            contents: Data("l".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "later.txt"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "later commit"])

        let service = GitService()

        // 详情:多行正文完整返回,邮箱/时间可解析。
        let detailResult = await service.commitDetail(hash: c2Hash, in: repository.path)
        let detail = try XCTUnwrap(detailResult)
        XCTAssertEqual(detail.hash, c2Hash)
        XCTAssertEqual(detail.authorEmail, "test@example.com")
        XCTAssertTrue(detail.fullMessage.contains("feature commit"))
        XCTAssertTrue(detail.fullMessage.contains("body line one"))
        XCTAssertNotNil(detail.date)

        // 非十六进制 hash 直接拒绝,不落到 git。
        let badDetail = await service.commitDetail(hash: "HEAD", in: repository.path)
        XCTAssertNil(badDetail)

        // 基于 c2 建分支并切换:新分支历史止于 c2,不含 later commit。
        try await service.createBranch("hotfix/from-c2", fromRev: c2Hash, in: repository.path)
        let currentBranch = await service.currentBranch(in: repository.path)
        XCTAssertEqual(currentBranch, "hotfix/from-c2")
        let subjects = await service.recentCommits(in: repository.path, count: 10).map(\.subject)
        XCTAssertEqual(subjects, ["feature commit", "base commit"])
    }

    /// 基于远端分支创建:本地**从未有过** origin/release/24 跟踪引用
    /// (另一份工作区推送后 fetch --prune 掉了),创建必须先 fetch 刷新引用再作基线;
    /// 并验证远端不存在的基线如实报错。
    func test_createBranchFromRemoteBranchFetchesStaleReferenceFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bareRemote = root.appendingPathComponent("remote.git")
        let publisher = root.appendingPathComponent("publisher")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "init", publisher.path])
        _ = try shell(["git", "-C", publisher.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", publisher.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", publisher.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: publisher.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", publisher.path, "add", "README.md"])
        _ = try shell(["git", "-C", publisher.path, "commit", "-m", "base commit"])
        _ = try shell(["git", "-C", publisher.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", publisher.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", clone.path, "config", "user.name", "test"])

        // 另一份工作区创建并推送 release/24,再在 clone 端把该引用清掉:
        // clone 从未 fetch 过它,origin/release/24 不存在。
        _ = try shell(["git", "-C", publisher.path, "checkout", "-b", "release/24"])
        FileManager.default.createFile(
            atPath: publisher.appendingPathComponent("rel.txt").path,
            contents: Data("r".utf8)
        )
        _ = try shell(["git", "-C", publisher.path, "add", "rel.txt"])
        _ = try shell(["git", "-C", publisher.path, "commit", "-m", "release work"])
        _ = try shell(["git", "-C", publisher.path, "push", "-u", "origin", "release/24"])
        _ = try shell(["git", "-C", clone.path, "fetch", "origin", "--prune"])
        _ = try shell([
            "git", "-C", clone.path, "update-ref", "-d", "refs/remotes/origin/release/24",
        ])

        let service = GitService()
        try await service.createBranch(
            fromRemoteBranch: "feature/off-release",
            baseBranch: "release/24",
            in: clone.path
        )

        let currentBranch = await service.currentBranch(in: clone.path)
        XCTAssertEqual(currentBranch, "feature/off-release")
        let subjects = await service.recentCommits(in: clone.path, count: 10).map(\.subject)
        XCTAssertEqual(subjects, ["release work", "base commit"])

        // 远端不存在的基线:fetch 即失败,如实抛错、不创建分支。
        await XCTAssertThrowsErrorAsync(GitServiceError.self) {
            try await service.createBranch(
                fromRemoteBranch: "feature/nope",
                baseBranch: "ghost-branch",
                in: clone.path
            )
        }
        let stillOn = await service.currentBranch(in: clone.path)
        XCTAssertEqual(stillOn, "feature/off-release")
    }

    private func shell(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "command failed: \(arguments.joined(separator: " "))\n\(stderr)"]
            )
        }

        return stdout
    }
}
