import XCTest

final class RunScriptTests: XCTestCase {
    /// 用测试文件自身路径反推仓库根,不依赖进程当前工作目录:
    /// 从其它目录运行 XCTest bundle 时,相对路径 "run.sh" 会直接读不到而失败。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CCSpaceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    func test_runScriptUsesAppBundleLauncherForRunCommand() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertFalse(script.contains(#""${DEBUG_BINARY}" >/tmp/${APP_NAME}.log 2>&1 &"#))
    }

    func test_readmeDoesNotRecommendSwiftRunForGuiLaunch() throws {
        let readme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("./run.sh"))
        XCTAssertFalse(readme.contains("swift run"))
    }

    /// vtool 外观补丁失败必须可见:此前 `|| true` 吞错后仍无条件打印 "Patched",
    /// 真失败时误导排查。只锁语义不变量——失败提示存在、vtool 调用行不吞错不静默——
    /// 不锁定具体变量名/命令拼接形式/调用行数等实现细节,避免重构即碎。
    func test_runScriptReportsVtoolPatchFailureInsteadOfSwallowing() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("vtool patch failed"))
        let vtoolLines = script.split(separator: "\n").filter { $0.contains("vtool -set-build-version") }
        XCTAssertFalse(vtoolLines.isEmpty, "run.sh 应存在 vtool 补丁调用,否则本测试没有覆盖对象")
        for line in vtoolLines {
            XCTAssertFalse(line.contains("|| true"), "vtool 调用行不得吞错: \(line)")
            XCTAssertFalse(line.contains(">/dev/null"), "vtool 调用行不得丢弃输出: \(line)")
        }
    }
}
