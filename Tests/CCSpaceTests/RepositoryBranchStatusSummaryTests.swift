import XCTest
@testable import CCSpace

final class RepositoryBranchStatusSummaryTests: XCTestCase {
    func test_pillsShowAheadAndBehindCounts() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "feature/demo",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: false,
                aheadCount: 2,
                behindCount: 3
            )
        )

        let titles = summary.pills.map(\.title)
        XCTAssertEqual(titles, ["领先 2 个", "落后 3 个"])
        XCTAssertEqual(summary.pills.map(\.tint), [.blue, .orange])
        XCTAssertEqual(summary.pills.map(\.action), [.push, .pull])
        XCTAssertEqual(summary.pills.first?.quickHelp, "领先远端 2 个提交，点击推送")
        XCTAssertEqual(summary.pills.last?.quickHelp, "落后远端 3 个提交，点击拉取")
        XCTAssertEqual(summary.pills.first?.effectiveAccessibilityTitle, "未推送 2 个提交")
        XCTAssertEqual(summary.pills.last?.effectiveAccessibilityTitle, "落后远端 3 个提交")
    }

    func test_pillsKeepUncommittedAndCountsOrdered() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "feature/demo",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: true,
                aheadCount: 1,
                behindCount: 4
            )
        )

        XCTAssertEqual(summary.pills.map(\.title), ["未提交", "领先 1 个", "落后 4 个"])
        XCTAssertEqual(summary.pills.map(\.action), [.viewUncommitted, .push, .pull])
    }

    func test_pillsShowCleanWhenNoChangesOrCounts() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "main",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: false
            )
        )

        XCTAssertEqual(summary.pills.map(\.title), ["干净"])
        XCTAssertEqual(summary.pills.map(\.effectiveAccessibilityTitle), ["干净"])
    }

    func test_pillsShowMissingUpstreamWithoutCounts() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "local-only",
                hasRemoteTrackingBranch: false,
                hasUncommittedChanges: false
            )
        )

        XCTAssertEqual(summary.pills.map(\.title), ["未关联远端"])
        XCTAssertEqual(summary.pills.map(\.action), [.push])
        XCTAssertEqual(summary.pills.first?.quickHelp, "点击推送并关联远端")
    }

    func test_pillsFallBackToSyncStatusWithoutBranchStatus() {
        let idle = RepositoryBranchStatusSummary(syncStatus: .idle, branchStatus: nil)
        XCTAssertEqual(idle.pills.map(\.title), ["未克隆"])

        let failed = RepositoryBranchStatusSummary(syncStatus: .failed, branchStatus: nil)
        XCTAssertEqual(failed.pills.map(\.title), ["异常"])
    }

    func test_conflictPillReplacesUncommittedAndKeepsCounts() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "feature/demo",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: true,
                aheadCount: 1,
                behindCount: 2,
                unmergedPaths: ["a.txt", "b/c.txt"]
            )
        )

        // 冲突是更紧急的"未提交"子集:取代未提交 pill,但仍保留领先/落后计数。
        XCTAssertEqual(summary.pills.map(\.title), ["冲突 2 个", "领先 1 个", "落后 2 个"])
        XCTAssertEqual(summary.pills.map(\.tint), [.red, .blue, .orange])
        XCTAssertEqual(summary.pills.map(\.action), [.viewConflicts, .push, .pull])
        XCTAssertEqual(summary.pills.first?.quickHelp, "点击查看冲突文件并中止操作")
        XCTAssertEqual(summary.pills.first?.effectiveAccessibilityTitle, "存在 2 个冲突文件")
    }

    func test_singleConflictPillShownWhenOnlyUnmergedChanges() {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: .success,
            branchStatus: GitBranchStatusSnapshot(
                currentBranch: "main",
                hasRemoteTrackingBranch: true,
                hasUncommittedChanges: true,
                unmergedPaths: ["f.txt"]
            )
        )

        XCTAssertEqual(summary.pills.map(\.title), ["冲突 1 个"])
        XCTAssertEqual(summary.pills.map(\.action), [.viewConflicts])
    }
}
