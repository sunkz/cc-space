import XCTest
@testable import CCSpace

final class GitBranchStatusSnapshotTests: XCTestCase {
    func test_parsePorcelainV2DetectsCleanTrackedBranch() {
        let output = """
        # branch.oid 2b1c57c9f8
        # branch.head 01
        # branch.upstream origin/01
        # branch.ab +0 -0
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertEqual(snapshot.currentBranch, "01")
        XCTAssertTrue(snapshot.hasRemoteTrackingBranch)
        XCTAssertFalse(snapshot.hasUncommittedChanges)
        XCTAssertEqual(snapshot.aheadCount, 0)
        XCTAssertEqual(snapshot.behindCount, 0)
        XCTAssertFalse(snapshot.hasUnpushedCommits)
        XCTAssertFalse(snapshot.isBehindRemote)
        XCTAssertTrue(snapshot.isClean)
    }

    func test_parsePorcelainV2DetectsDirtyAheadBehindBranch() {
        let output = """
        # branch.oid 2b1c57c9f8
        # branch.head feature/demo
        # branch.upstream origin/feature/demo
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 4d3f7d2 4d3f7d2 Sources/App.swift
        ? README.local.md
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertEqual(snapshot.currentBranch, "feature/demo")
        XCTAssertTrue(snapshot.hasRemoteTrackingBranch)
        XCTAssertTrue(snapshot.hasUncommittedChanges)
        XCTAssertEqual(snapshot.aheadCount, 2)
        XCTAssertEqual(snapshot.behindCount, 1)
        XCTAssertTrue(snapshot.hasUnpushedCommits)
        XCTAssertTrue(snapshot.isBehindRemote)
        XCTAssertFalse(snapshot.isClean)
    }

    func test_parsePorcelainV2DetectsBranchWithoutUpstream() {
        let output = """
        # branch.oid 2b1c57c9f8
        # branch.head local-only
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertEqual(snapshot.currentBranch, "local-only")
        XCTAssertFalse(snapshot.hasRemoteTrackingBranch)
        XCTAssertFalse(snapshot.hasUncommittedChanges)
        XCTAssertEqual(snapshot.aheadCount, 0)
        XCTAssertEqual(snapshot.behindCount, 0)
        XCTAssertFalse(snapshot.hasUnpushedCommits)
        XCTAssertFalse(snapshot.isBehindRemote)
        XCTAssertFalse(snapshot.isClean)
    }

    func test_parsePorcelainV2KeepsLargerCounts() {
        let output = """
        # branch.oid 2b1c57c9f8
        # branch.head release/1.2
        # branch.upstream origin/release/1.2
        # branch.ab +12 -34
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertEqual(snapshot.aheadCount, 12)
        XCTAssertEqual(snapshot.behindCount, 34)
    }

    func test_hasUnpushedCommitsAndIsBehindRemoteDeriveFromCounts() {
        let snapshot = GitBranchStatusSnapshot(
            currentBranch: "main",
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false,
            aheadCount: 3,
            behindCount: 5
        )

        XCTAssertTrue(snapshot.hasUnpushedCommits)
        XCTAssertTrue(snapshot.isBehindRemote)

        let cleanCounts = GitBranchStatusSnapshot(
            currentBranch: "main",
            hasRemoteTrackingBranch: true,
            hasUncommittedChanges: false
        )

        XCTAssertFalse(cleanCounts.hasUnpushedCommits)
        XCTAssertFalse(cleanCounts.isBehindRemote)
    }

    // MARK: - 冲突(unmerged)解析

    func test_parsePorcelainV2CollectsUnmergedPaths() {
        // 行内容为 git 2.39 真实输出(`git status --porcelain=2 --branch`,合并冲突中)。
        let output = """
        # branch.oid b44c9971dcde
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        1 M. N... 100644 100644 100644 83126302079c c7747099cf9e g.txt
        u UU N... 100644 100644 100644 100644 83db48f84ec8 6319821edd75 fb81947c338d f.txt
        u AA N... 100644 100644 100644 100644 000000000000 111111111111 222222222222 new/both_added.txt
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertTrue(snapshot.hasConflicts)
        XCTAssertEqual(snapshot.conflictCount, 2)
        XCTAssertEqual(snapshot.unmergedPaths, ["f.txt", "new/both_added.txt"])
        XCTAssertTrue(snapshot.hasUncommittedChanges)
        XCTAssertFalse(snapshot.isClean)
        XCTAssertNil(snapshot.interruptedOperation)
    }

    func test_parsePorcelainV2KeepsSpacesAndTabOrigPathInUnmergedPaths() {
        // 路径含空格(maxSplits 保住剩余整体)与 rename 冲突的 tab 缀原路径。
        let spacedPath = "u UU N... 100644 100644 100644 100644 83db48f8 6319821e fb81947c dir/my conflicted file.txt"
        let renamePath = "u UU N... 100644 100644 100644 100644 83db48f8 6319821e fb81947c new/name.txt\told/name.txt"

        XCTAssertEqual(
            GitBranchStatusSnapshot.unmergedPath(fromLine: spacedPath),
            "dir/my conflicted file.txt"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.unmergedPath(fromLine: renamePath),
            "new/name.txt"
        )
        XCTAssertNil(GitBranchStatusSnapshot.unmergedPath(fromLine: "1 M. N... 100644 100644 100644 a b file.txt"))
    }

    func test_decodePorcelainPathUnquotesCStyleEscapes() {
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"\\346\\226\\207\\344\\273\\266.txt\""),
            "文件.txt"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"quote\\\".txt\""),
            "quote\".txt"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"tab\\there.txt\""),
            "tab\there.txt"
        )
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("\"back\\\\slash.txt\""),
            "back\\slash.txt"
        )
        // 非引用路径原样返回。
        XCTAssertEqual(
            GitBranchStatusSnapshot.decodePorcelainPath("plain/path.txt"),
            "plain/path.txt"
        )
    }

    func test_parsePorcelainV2WithoutUnmergedLinesHasNoConflicts() {
        let output = """
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """

        let snapshot = GitBranchStatusSnapshot.parsePorcelainV2(output)

        XCTAssertFalse(snapshot.hasConflicts)
        XCTAssertEqual(snapshot.conflictCount, 0)
        XCTAssertTrue(snapshot.isClean)
    }
}

final class GitInterruptedOperationTests: XCTestCase {
    func test_detectPrefersRebaseAndSequencerMarkersOverMergeHead() {
        // cherry-pick/revert/变基现场常同时存在 MERGE_HEAD,
        // 探测必须按优先级返回更具体的操作,否则会误用 `merge --abort`。
        let existing: Set<String> = [
            "/repo/.git/MERGE_HEAD",
            "/repo/.git/CHERRY_PICK_HEAD",
        ]
        let operation = GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") {
            existing.contains($0)
        }
        XCTAssertEqual(operation, .cherryPick)

        let rebaseWithMergeHead: Set<String> = [
            "/repo/.git/MERGE_HEAD",
            "/repo/.git/rebase-merge",
        ]
        XCTAssertEqual(
            GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") {
                rebaseWithMergeHead.contains($0)
            },
            .rebase
        )

        XCTAssertEqual(
            GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") {
                $0 == "/repo/.git/MERGE_HEAD"
            },
            .merge
        )
        XCTAssertEqual(
            GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") {
                $0 == "/repo/.git/BISECT_LOG"
            },
            .bisect
        )
        XCTAssertNil(GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") { _ in false })
    }

    func test_rebaseMatchesApplyDirectoryWithoutRebaseMerge() {
        XCTAssertEqual(
            GitInterruptedOperation.detect(gitDirectoryPath: "/repo/.git") {
                $0 == "/repo/.git/rebase-apply"
            },
            .rebase
        )
    }

    func test_abortArgumentsMapToMatchingGitSubcommand() {
        XCTAssertEqual(GitInterruptedOperation.merge.abortArguments, ["merge", "--abort"])
        XCTAssertEqual(GitInterruptedOperation.rebase.abortArguments, ["rebase", "--abort"])
        XCTAssertEqual(GitInterruptedOperation.cherryPick.abortArguments, ["cherry-pick", "--abort"])
        XCTAssertEqual(GitInterruptedOperation.revert.abortArguments, ["revert", "--abort"])
        XCTAssertEqual(GitInterruptedOperation.bisect.abortArguments, ["bisect", "reset"])
    }
}
