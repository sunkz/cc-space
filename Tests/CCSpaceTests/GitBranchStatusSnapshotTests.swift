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
        XCTAssertFalse(snapshot.hasUnpushedCommits)
        XCTAssertFalse(snapshot.isBehindRemote)
        XCTAssertFalse(snapshot.isClean)
    }
}
