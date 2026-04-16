import XCTest

final class RunScriptTests: XCTestCase {
    func test_runScriptUsesAppBundleLauncherForRunCommand() throws {
        let script = try String(contentsOfFile: "run.sh", encoding: .utf8)

        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertFalse(script.contains(#""${DEBUG_BINARY}" >/tmp/${APP_NAME}.log 2>&1 &"#))
    }

    func test_readmeDoesNotRecommendSwiftRunForGuiLaunch() throws {
        let readme = try String(contentsOfFile: "README.md", encoding: .utf8)

        XCTAssertTrue(readme.contains("./run.sh"))
        XCTAssertFalse(readme.contains("swift run"))
    }
}
