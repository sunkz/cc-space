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

    func test_pointerBoundsKeepsTooltipVisibleWithinExitTolerance() {
        let bounds = CCSpaceQuickHelpPointerBounds(bounds: CGRect(x: 0, y: 0, width: 32, height: 20))

        XCTAssertTrue(bounds.contains(CGPoint(x: -2, y: 10)))
        XCTAssertTrue(bounds.contains(CGPoint(x: 34, y: 10)))
    }

    func test_pointerBoundsClosesTooltipOncePointerClearlyLeavesTarget() {
        let bounds = CCSpaceQuickHelpPointerBounds(bounds: CGRect(x: 0, y: 0, width: 32, height: 20))

        XCTAssertFalse(bounds.contains(CGPoint(x: -8, y: 10)))
        XCTAssertFalse(bounds.contains(CGPoint(x: 40, y: 10)))
        XCTAssertFalse(bounds.contains(CGPoint(x: 10, y: 28)))
    }
}
