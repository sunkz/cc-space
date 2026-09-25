import XCTest
@testable import CCSpace

final class BranchNameDisplayTests: XCTestCase {
    func test_displayTextKeepsShortNamesVerbatim() {
        XCTAssertEqual(BranchNameDisplay.displayText(for: "main"), "main")
        let exactly = String(repeating: "a", count: BranchNameDisplay.maxDisplayCharacters)
        XCTAssertEqual(BranchNameDisplay.displayText(for: exactly), exactly)
    }

    func test_displayTextKeepsPrefixAndTailForLongBranch() {
        let branch = "feature/checkout-redesign-20260922-with-a-very-long-suffix-name"
        let display = BranchNameDisplay.displayText(for: branch)

        // 保留层级前缀 + 省略号 + 尾部最具区分度的部分。
        XCTAssertTrue(display.hasPrefix("feature/"))
        XCTAssertTrue(display.contains("…"))
        XCTAssertTrue(display.hasSuffix(String(branch.suffix(10))))
        XCTAssertLessThanOrEqual(display.count, BranchNameDisplay.maxDisplayCharacters)
    }

    func test_displayTextWithoutSlashOnlyKeepsTail() {
        let branch = String(repeating: "x", count: 80)
        let display = BranchNameDisplay.displayText(for: branch)

        XCTAssertTrue(display.hasPrefix("…"))
        XCTAssertTrue(display.hasSuffix(String(branch.suffix(10))))
        XCTAssertLessThanOrEqual(display.count, BranchNameDisplay.maxDisplayCharacters)
    }
}
