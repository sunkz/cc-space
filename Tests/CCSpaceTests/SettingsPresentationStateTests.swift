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
