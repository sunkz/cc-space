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
    /// 真失败时误导排查。锁定"走 if ! 判错分支、vtool 调用行无静默吞错"两个特征。
    /// 负向断言逐行匹配模式而非整段旧实现原文:匹配精确多行字符串的断言,
    /// 只要换种格式重新引入吞错就恒真,锁不住任何东西。
    func test_runScriptReportsVtoolPatchFailureInsteadOfSwallowing() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("vtool patch failed"))
        XCTAssertTrue(script.contains("if ! patch_output="))
        let vtoolLines = script.split(separator: "\n").filter { $0.contains("vtool -set-build-version") }
        XCTAssertEqual(vtoolLines.count, 1)
        for line in vtoolLines {
            XCTAssertFalse(line.contains("|| true"), "vtool 调用行不得吞错: \(line)")
            XCTAssertFalse(line.contains(">/dev/null"), "vtool 调用行不得丢弃输出: \(line)")
        }
    }
}
