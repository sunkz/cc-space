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

    /// 检查中/检查失败都挂在同一处悬浮文案与无障碍名称上:要能归因,
    /// 但不做成醒目横幅(后台每小时重试,私有仓库或离线时失败是常态)。
    func test_fallsBackToPlainTitleBeforeFirstCheckCompletes() {
        let state = makeState(latestVersion: nil, isChecking: true)

        XCTAssertEqual(
            state.title,
            "获取更新：前往 GitHub Releases 查看最新版本（正在检查更新…）"
        )
        XCTAssertFalse(state.usesAccentTint)
    }

    func test_appendsFailureHintToTitleWithoutChangingTint() {
        let state = UpdateButtonPresentationState(
            updatePresentationState: SettingsUpdatePresentationState(
                currentVersion: "0.0.3",
                latestVersion: nil,
                isChecking: false,
                lastErrorMessage: "检查更新失败：HTTP 404"
            )
        )

        XCTAssertEqual(
            state.title,
            "获取更新：前往 GitHub Releases 查看最新版本（检查更新失败：HTTP 404）"
        )
        XCTAssertFalse(state.usesAccentTint, "检查失败不该把入口标成强调色")
    }

    /// 发现新版本时不再叠加提示文案(按钮文案已含版本号)。
    func test_noRedundantHintWhenUpdateAvailable() {
        let state = makeState(currentVersion: "0.0.3", latestVersion: "0.1.0")

        XCTAssertFalse(state.title.contains("（"), state.title)
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
