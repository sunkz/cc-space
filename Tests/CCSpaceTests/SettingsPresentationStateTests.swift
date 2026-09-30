import XCTest
@testable import CCSpace

final class SettingsPresentationStateTests: XCTestCase {
    func test_updateStateShowsWarningWhenNewVersionAvailable() {
        let presentationState = SettingsUpdatePresentationState(
            currentVersion: "0.0.1",
            latestVersion: "0.2.0",
            isChecking: false,
            lastErrorMessage: nil
        )

        XCTAssertEqual(presentationState.currentVersionDisplay, "v0.0.1")
        XCTAssertEqual(presentationState.latestVersionDisplay, "v0.2.0")
        XCTAssertTrue(presentationState.showsUpdateAvailable)
        XCTAssertEqual(
            presentationState.statusFeedback,
            CCSpaceFeedback(
                style: .warning,
                message: "发现新版本 v0.2.0，可前往 Releases 下载。"
            )
        )
    }

    func test_updateStateShowsSuccessWhenCurrentVersionIsLatest() {
        let presentationState = SettingsUpdatePresentationState(
            currentVersion: "0.0.1",
            latestVersion: "0.0.1",
            isChecking: false,
            lastErrorMessage: nil
        )

        XCTAssertFalse(presentationState.showsUpdateAvailable)
        XCTAssertEqual(
            presentationState.statusFeedback,
            CCSpaceFeedback(
                style: .success,
                message: "当前已是最新版本 v0.0.1。"
            )
        )
    }

    func test_updateStatePrefersErrorFeedbackOverOtherStatus() {
        let presentationState = SettingsUpdatePresentationState(
            currentVersion: "0.0.1",
            latestVersion: "0.2.0",
            isChecking: false,
            lastErrorMessage: "检查更新失败：HTTP 403"
        )

        XCTAssertEqual(
            presentationState.statusFeedback,
            CCSpaceFeedback(
                style: .error,
                message: "检查更新失败：HTTP 403"
            )
        )
    }
}

final class SettingsTabPresentationStateTests: XCTestCase {
    func test_allTabsOrderAndTitles() {
        XCTAssertEqual(SettingsTabPresentationState.allTabs, [.general, .ai])
        // 页签在设置页内部,不自称"设置"(自指),与内容范围一致叫"通用"。
        XCTAssertEqual(SettingsTab.general.title, "通用")
        XCTAssertEqual(SettingsTab.ai.title, "AI")
    }

    func test_tabIconsOnlyAIHasIcon() {
        XCTAssertNil(SettingsTab.general.iconSystemName)
        XCTAssertEqual(SettingsTab.ai.iconSystemName, "sparkles")
    }

    func test_pickerTitlesUseUnicodeStarForIconTabs() {
        XCTAssertEqual(SettingsTab.general.pickerTitle(), "通用")
        XCTAssertEqual(SettingsTab.ai.pickerTitle(), "✦ AI")
        XCTAssertEqual(
            SettingsTab.ai.pickerTitle(showingUnsavedChanges: true),
            "✦ AI •",
            "未保存标记以「•」追加在段标题尾部"
        )
    }

    func test_unsavedChangesMarkerOnlyAppearsOnAITab() {
        let state = SettingsTabPresentationState(selectedTab: .general, showsUnsavedChanges: true)

        XCTAssertEqual(
            state.pickerTitle(for: .ai),
            "✦ AI •",
            "AI 表单有未保存修改时,AI 页签带「•」标记"
        )
        XCTAssertEqual(
            state.pickerTitle(for: .general),
            "通用",
            "通用页签没有表单输入,恒不带未保存标记"
        )

        let cleanState = SettingsTabPresentationState(selectedTab: .general)
        XCTAssertEqual(cleanState.pickerTitle(for: .ai), "✦ AI")
    }

    func test_selectionAndAccessibilityLabels() {
        let state = SettingsTabPresentationState(selectedTab: .ai)
        XCTAssertTrue(state.isSelected(.ai))
        XCTAssertFalse(state.isSelected(.general))
        XCTAssertEqual(state.accessibilityLabel(for: .ai), "AI（当前页签）")
        XCTAssertEqual(state.accessibilityLabel(for: .general), "通用")
    }
}
