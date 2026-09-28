import XCTest
@testable import CCSpace

final class GitEnvironmentPresentationStateTests: XCTestCase {
    func test_checkingWhenDetectionInProgress() {
        let state = GitEnvironmentPresentationState(info: nil, isChecking: true)

        XCTAssertEqual(state.availability, .checking)
        XCTAssertNil(state.versionDisplay)
        XCTAssertNil(state.executablePathDisplay)
    }

    func test_checkingTakesPrecedenceOverStaleResult() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "git version 2.39.5",
            executablePath: "/usr/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: true)

        XCTAssertEqual(state.availability, .checking)
    }

    func test_availableWhenGitVersionSucceeds() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "git version 2.39.5 (Apple Git-150)\n",
            executablePath: "/usr/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(state.availability, .available)
        XCTAssertEqual(state.versionDisplay, "git version 2.39.5 (Apple Git-150)")
        XCTAssertEqual(state.executablePathDisplay, "/usr/bin/git")
    }

    func test_unavailableWhenVersionMissingButPathFound() {
        let info = GitEnvironmentInfo(
            isAvailable: false,
            version: nil,
            executablePath: "/usr/local/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(state.availability, .unavailable)
        XCTAssertNil(state.versionDisplay)
        XCTAssertEqual(state.executablePathDisplay, "/usr/local/bin/git")
    }

    func test_unavailableWhenNoDetectionResult() {
        let state = GitEnvironmentPresentationState(info: nil, isChecking: false)

        XCTAssertEqual(state.availability, .unavailable)
        XCTAssertNil(state.versionDisplay)
        XCTAssertNil(state.executablePathDisplay)
    }

    func test_blankStringsAreNormalizedToNil() {
        let info = GitEnvironmentInfo(
            isAvailable: false,
            version: "  ",
            executablePath: ""
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertNil(state.versionDisplay)
        XCTAssertNil(state.executablePathDisplay)
    }

    // MARK: - shortVersionDisplay

    func test_shortVersionParsesAppleGitOutput() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "git version 2.39.5 (Apple Git-150)",
            executablePath: nil
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(state.shortVersionDisplay, "2.39.5")
    }

    func test_shortVersionIsNilForNonStandardOutput() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "自定义 git 构建",
            executablePath: nil
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertNil(state.shortVersionDisplay)
    }

    // MARK: - compactLabel

    func test_compactLabelShowsVersionWhenAvailable() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "git version 2.39.5 (Apple Git-150)",
            executablePath: "/usr/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(state.compactLabel, "git 2.39.5")
    }

    func test_compactLabelFallsBackWhenVersionUnparsable() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "自定义 git 构建",
            executablePath: "/usr/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(state.compactLabel, "git 可用")
    }

    func test_compactLabelShowsUnavailableText() {
        let state = GitEnvironmentPresentationState(info: nil, isChecking: false)

        XCTAssertEqual(state.compactLabel, "git 不可用")
    }

    func test_compactLabelIsNilWhileChecking() {
        let state = GitEnvironmentPresentationState(info: nil, isChecking: true)

        XCTAssertNil(state.compactLabel)
    }

    // MARK: - quickHelpText

    func test_quickHelpIncludesVersionAndPathWhenAvailable() {
        let info = GitEnvironmentInfo(
            isAvailable: true,
            version: "git version 2.39.5 (Apple Git-150)",
            executablePath: "/usr/bin/git"
        )

        let state = GitEnvironmentPresentationState(info: info, isChecking: false)

        XCTAssertEqual(
            state.quickHelpText,
            "git 可用\n版本：git version 2.39.5 (Apple Git-150)\n路径：/usr/bin/git\n点击重新检测"
        )
    }

    func test_quickHelpSuggestsCommandLineToolsWhenUnavailable() {
        let state = GitEnvironmentPresentationState(info: nil, isChecking: false)

        XCTAssertEqual(
            state.quickHelpText,
            "未检测到可用的 git，可安装 Xcode Command Line Tools 后重新检测"
        )
    }
}
