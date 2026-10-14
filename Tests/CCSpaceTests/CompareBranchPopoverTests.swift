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

}
