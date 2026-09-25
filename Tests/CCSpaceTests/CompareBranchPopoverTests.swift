import XCTest
@testable import CCSpace

final class CompareBranchPopoverTests: XCTestCase {
    func test_filterIsCaseInsensitiveAndTrimmed() {
        let state = CompareBranchListPresentationState(
            branches: ["main", "Feature/X", "origin/release"],
            searchText: "  feature  "
        )

        XCTAssertEqual(state.filteredBranches, ["Feature/X"])
        XCTAssertEqual(state.emptyTitle, "")
    }

    func test_emptyBranchesShowsPlaceholder() {
        let state = CompareBranchListPresentationState(branches: [], searchText: "")

        XCTAssertTrue(state.filteredBranches.isEmpty)
        XCTAssertEqual(state.emptyTitle, "暂无可对比的分支")
    }

    func test_noSearchMatchShowsHint() {
        let state = CompareBranchListPresentationState(branches: ["main"], searchText: "zzz")

        XCTAssertTrue(state.filteredBranches.isEmpty)
        XCTAssertEqual(state.emptyTitle, "未找到匹配分支")
        XCTAssertEqual(state.emptySubtitle, "试试分支名中的关键词。")
    }

    func test_listHeightIsFixedAndIgnoresSearchFilter() {
        // 与切换分支弹窗共用固定高度:分支数、搜索词都不改变面板高度。
        let single = CompareBranchListPresentationState(branches: ["main"], searchText: "")
        XCTAssertEqual(single.listHeight, BranchSwitchListPresentationState.fixedListHeight)

        let many = CompareBranchListPresentationState(
            branches: (0..<50).map { "branch-\($0)" },
            searchText: ""
        )
        XCTAssertEqual(many.listHeight, BranchSwitchListPresentationState.fixedListHeight)

        let filtered = CompareBranchListPresentationState(
            branches: (0..<50).map { "branch-\($0)" },
            searchText: "branch-1"
        )
        XCTAssertEqual(filtered.listHeight, many.listHeight)
    }
}
