import Foundation
import XCTest
@testable import CCSpace

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func test_checkUpdatesLatestVersionAndMarksUpdateAvailable() async throws {
        let apiURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/sunkz/cc-space/releases/latest"))
        let releasesURL = try XCTUnwrap(URL(string: "https://github.com/sunkz/cc-space/releases"))

        let checker = UpdateChecker(
            currentVersion: "0.0.1",
            releasesURL: releasesURL,
            latestReleaseAPIURL: apiURL,
            dataLoader: { request in
                XCTAssertEqual(request.url, apiURL)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CCSpace/0.0.1")

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: apiURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                let data = Data(#"{"tag_name":"v0.2.0"}"#.utf8)
                return (data, response)
            }
        )

        await checker.check()

        XCTAssertEqual(checker.latestVersion, "0.2.0")
        XCTAssertTrue(checker.hasUpdate)
        XCTAssertFalse(checker.isChecking)
        XCTAssertNil(checker.lastErrorMessage)
    }

    func test_checkStoresHTTPErrorMessage() async throws {
        let apiURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/sunkz/cc-space/releases/latest"))

        let checker = UpdateChecker(
            currentVersion: "0.0.1",
            latestReleaseAPIURL: apiURL,
            dataLoader: { _ in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: apiURL,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                return (Data(), response)
            }
        )

        await checker.check()

        XCTAssertEqual(checker.lastErrorMessage, "检查更新失败：HTTP 503")
        XCTAssertNil(checker.latestVersion)
        XCTAssertFalse(checker.hasUpdate)
    }

    func test_checkStoresDecoderErrorMessageWhenPayloadInvalid() async throws {
        let apiURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/sunkz/cc-space/releases/latest"))

        let checker = UpdateChecker(
            currentVersion: "0.0.1",
            latestReleaseAPIURL: apiURL,
            dataLoader: { _ in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: apiURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                return (Data(#"{"name":"0.2.0"}"#.utf8), response)
            }
        )

        await checker.check()

        XCTAssertNotNil(checker.lastErrorMessage)
        XCTAssertTrue(checker.lastErrorMessage?.hasPrefix("检查更新失败：") == true)
        XCTAssertNil(checker.latestVersion)
    }

    func test_isNewerVersionTreatsStableReleaseAsNewerThanPrerelease() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.0.0", than: "1.0.0-beta.1"))
    }

    func test_devFallbackVersionNeverReportsUpdate() async throws {
        // 无 bundle 的开发运行回退 "0",不应把任何远端版本判定为更新。
        let apiURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/sunkz/cc-space/releases/latest"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: apiURL, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let data = Data(#"{"tag_name":"v9.9.9"}"#.utf8)

        let checker = UpdateChecker(
            currentVersion: "0",
            latestReleaseAPIURL: apiURL,
            dataLoader: { _ in (data, response) }
        )

        await checker.check()

        XCTAssertEqual(checker.latestVersion, "9.9.9")
        XCTAssertFalse(checker.hasUpdate)
    }

    func test_isNewerVersionComparesPrereleaseIdentifiers() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.0.0-beta.2", than: "1.0.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.0.0-beta.1", than: "1.0.0-beta.2"))
    }
}
