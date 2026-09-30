import XCTest
@testable import CCSpace

final class UpdateButtonPresentationStateTests: XCTestCase {
    private func makeState(
        currentVersion: String = "0.0.3",
        latestVersion: String?,
        isChecking: Bool = false
    ) -> UpdateButtonPresentationState {
        UpdateButtonPresentationState(
            updatePresentationState: SettingsUpdatePresentationState(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                isChecking: isChecking,
                lastErrorMessage: nil
            )
        )
    }

    func test_mentionsLatestVersionWhenUpdateAvailable() {
        let state = makeState(currentVersion: "0.0.3", latestVersion: "0.1.0")

        XCTAssertEqual(state.title, "获取更新：发现新版本 v0.1.0，点击前往 GitHub Releases 下载")
        XCTAssertTrue(state.usesAccentTint)
    }

    func test_usesPlainTitleWhenAlreadyUpToDate() {
        let state = makeState(currentVersion: "0.0.3", latestVersion: "0.0.3")

        XCTAssertEqual(state.title, "获取更新：前往 GitHub Releases 查看最新版本")
        XCTAssertFalse(state.usesAccentTint)
    }

    func test_fallsBackToPlainTitleBeforeFirstCheckCompletes() {
        let state = makeState(latestVersion: nil, isChecking: true)

        XCTAssertEqual(state.title, "获取更新：前往 GitHub Releases 查看最新版本")
        XCTAssertFalse(state.usesAccentTint)
    }

    /// 图标按钮没有可见文字,按钮名称完全依赖 title;空文案等于 VoiceOver 下无名控件。
    func test_titleIsNeverEmpty() {
        for latestVersion in [nil, "0.0.3", "9.9.9"] {
            let state = makeState(latestVersion: latestVersion)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertTrue(state.title.hasPrefix("获取更新："))
        }
    }
}
