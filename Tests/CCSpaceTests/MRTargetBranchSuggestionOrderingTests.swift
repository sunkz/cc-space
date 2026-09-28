import XCTest
@testable import CCSpace

/// MR 目标分支建议排序纯函数测试:已选置顶 + 同级字典序(消除不稳定排序的换位)。
final class MRTargetBranchSuggestionOrderingTests: XCTestCase {
    func test_selectedBranchesFloatToTop() {
        let result = MRTargetBranchSuggestionOrdering.sortedSuggestions(
            ["feat-a", "main", "feat-b"],
            selectedBranches: ["feat-b"]
        )

        XCTAssertEqual(result, ["feat-b", "feat-a", "main"])
    }

    func test_sameSelectionLevel_isSortedDeterministicallyByName() {
        let suggestions = ["release/2", "alpha", "zeta", "master"]

        let first = MRTargetBranchSuggestionOrdering.sortedSuggestions(
            suggestions,
            selectedBranches: []
        )
        let second = MRTargetBranchSuggestionOrdering.sortedSuggestions(
            suggestions.shuffled(),
            selectedBranches: []
        )

        XCTAssertEqual(first, ["alpha", "master", "release/2", "zeta"])
        XCTAssertEqual(first, second)
    }

    func test_multipleSelected_keepRelativeOrderByName() {
        let result = MRTargetBranchSuggestionOrdering.sortedSuggestions(
            ["unselected", "beta-selected", "alpha-selected"],
            selectedBranches: ["beta-selected", "alpha-selected"]
        )

        XCTAssertEqual(result, ["alpha-selected", "beta-selected", "unselected"])
    }
}
