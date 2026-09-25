import XCTest
@testable import CCSpace

final class DiffWindowEmptyStateResolverTests: XCTestCase {
    func test_workingDirectoryAfterCommitShowsCommittedState() {
        let state = DiffWindowEmptyStateResolver.resolve(source: .workingDirectory, didCommit: true)

        XCTAssertEqual(state, .committed)
        XCTAssertEqual(state.title, "提交成功")
    }

    func test_workingDirectoryWithoutCommitShowsPendingChangesCopy() {
        let state = DiffWindowEmptyStateResolver.resolve(source: .workingDirectory, didCommit: false)

        XCTAssertEqual(state, .noPendingChanges)
        // 单侧来源(工作区未提交改动)没有"两侧比较"语义,不能用"两侧内容完全一致"。
        XCTAssertEqual(state.subtitle, "没有待展示的改动")
    }

    func test_commitSourceUsesSingleSideCopy() {
        let state = DiffWindowEmptyStateResolver.resolve(source: .commit(hash: "abc123"), didCommit: false)

        XCTAssertEqual(state, .noCommitChanges)
        XCTAssertEqual(state.subtitle, "该提交没有可展示的改动")
    }

    func test_compareSourceKeepsTwoSideCopy() {
        let state = DiffWindowEmptyStateResolver.resolve(source: .compare(base: "main", head: "feat"), didCommit: false)

        XCTAssertEqual(state, .noChanges)
        XCTAssertEqual(state.subtitle, "两侧内容完全一致")
    }

    func test_nonWorkingDirectorySourcesNeverShowCommittedState() {
        // 提交栏只在工作区改动来源出现,这里防御历史 diff/分支对比误染"提交成功"。
        XCTAssertEqual(
            DiffWindowEmptyStateResolver.resolve(source: .commit(hash: "abc123"), didCommit: true),
            .noCommitChanges
        )
        XCTAssertEqual(
            DiffWindowEmptyStateResolver.resolve(source: .compare(base: "main", head: "feat"), didCommit: true),
            .noChanges
        )
    }

    func test_committedStateCopyIsActionOutcomeNotNoChanges() {
        // 回归锚点:提交成功空态不能回落到"没有改动"式的文案。
        XCTAssertFalse(DiffViewerEmptyState.committed.title.contains("没有改动"))
        XCTAssertFalse(DiffViewerEmptyState.committed.subtitle.isEmpty)
    }
}
