import XCTest
@testable import CCSpace

final class CCSpaceQuickHelpLayoutMetricsTests: XCTestCase {
    func test_shortTooltipUsesCompactWidth() {
        let metrics = CCSpaceQuickHelpLayoutMetrics(text: "更多操作")

        XCTAssertLessThan(metrics.textWidth, CCSpaceQuickHelpLayoutMetrics.maxTextWidth)
        XCTAssertEqual(
            metrics.popoverSize.width,
            ceil(metrics.textWidth + (CCSpaceQuickHelpLayoutMetrics.horizontalPadding * 2)),
            accuracy: 0.5
        )
    }

    func test_longTooltipCapsWidthAndWrapsToMultipleLines() {
        let shortMetrics = CCSpaceQuickHelpLayoutMetrics(text: "同步")
        let longMetrics = CCSpaceQuickHelpLayoutMetrics(
            text: "这个操作会同步当前工作区下的所有仓库状态，并在需要时更新本地分支与远端分支之间的差异。"
        )

        XCTAssertEqual(
            longMetrics.textWidth,
            CCSpaceQuickHelpLayoutMetrics.maxTextWidth,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(longMetrics.popoverSize.height, shortMetrics.popoverSize.height)
    }
}
