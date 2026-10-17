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
        // 按钮文案已含"发现新版本",状态提示此处应为 nil,不重复第二遍。
        XCTAssertNil(presentationState.statusHint)
    }

    func test_updateStateShowsSuccessWhenCurrentVersionIsLatest() {
        let presentationState = SettingsUpdatePresentationState(
            currentVersion: "0.0.1",
            latestVersion: "0.0.1",
            isChecking: false,
            lastErrorMessage: nil
        )

        XCTAssertFalse(presentationState.showsUpdateAvailable)
        // 已是最新:按钮不高亮本身就是结论,不再叠一句文案。
        XCTAssertNil(presentationState.statusHint)
    }

    func test_updateStatePrefersErrorFeedbackOverOtherStatus() {
        let presentationState = SettingsUpdatePresentationState(
            currentVersion: "0.0.1",
            latestVersion: "0.2.0",
            isChecking: false,
            lastErrorMessage: "检查更新失败：HTTP 403"
        )

        XCTAssertEqual(presentationState.statusHint, "检查更新失败：HTTP 403")
    }
}
