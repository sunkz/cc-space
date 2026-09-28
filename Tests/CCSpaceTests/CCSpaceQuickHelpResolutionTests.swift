import XCTest
@testable import CCSpace

/// ccspaceQuickHelp 的 label/hint 三分支是纯逻辑,抽到 CCSpaceQuickHelpResolution
/// 后按矩阵断言;视图只负责按 resolve 结果挂 accessibility 属性,渲染本身不测。
final class CCSpaceQuickHelpResolutionTests: XCTestCase {
    func test_defaultPathAttachesHintOnly() {
        let resolution = CCSpaceQuickHelpResolution.resolve(text: "更多操作")

        XCTAssertNil(resolution.label)
        XCTAssertEqual(resolution.hint, "更多操作")
    }

    func test_providesLabelUsesTextAsLabelWithoutRepeatingHint() {
        // providesLabel 的调用点(图标按钮)label 恒等于 text,且不得再重复挂 hint。
        let resolution = CCSpaceQuickHelpResolution.resolve(text: "同步", providesLabel: true)

        XCTAssertEqual(resolution.label, "同步")
        XCTAssertNil(resolution.hint)
    }

    func test_explicitLabelAndHintBothAttached() {
        let resolution = CCSpaceQuickHelpResolution.resolve(
            text: "悬浮文案",
            label: "无障碍名称",
            hint: "无障碍提示"
        )

        XCTAssertEqual(resolution.label, "无障碍名称")
        XCTAssertEqual(resolution.hint, "无障碍提示")
    }

    func test_equalLabelAndHintKeepsOnlyLabel() {
        // 显式 label == hint 去重;label == text(默认 hint)同样去重。
        let explicit = CCSpaceQuickHelpResolution.resolve(
            text: "气泡文案",
            label: "同步",
            hint: "同步"
        )
        XCTAssertEqual(explicit.label, "同步")
        XCTAssertNil(explicit.hint)

        let labelEqualsText = CCSpaceQuickHelpResolution.resolve(text: "同步", label: "同步")
        XCTAssertEqual(labelEqualsText.label, "同步")
        XCTAssertNil(labelEqualsText.hint)
    }

    func test_emptyTextSkipsQuickHelpEntirely() {
        XCTAssertEqual(
            CCSpaceQuickHelpResolution.resolve(text: ""),
            CCSpaceQuickHelpResolution(label: nil, hint: nil)
        )
        XCTAssertEqual(
            CCSpaceQuickHelpResolution.resolve(text: nil),
            CCSpaceQuickHelpResolution(label: nil, hint: nil)
        )
    }
}
