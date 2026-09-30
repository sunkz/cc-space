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
        // 启动器必须真的指向 .app bundle:此前第二条断言是拿整行字面量
        // (`"${DEBUG_BINARY}" >/tmp/${APP_NAME}.log 2>&1 &`) 做反向匹配,
        // 而 run.sh 里早已不存在 DEBUG_BINARY——那条断言恒真,拦不住任何回归。
        // 改为锁语义要素:不得有"裸产物后台启动 + /tmp 日志"的形态。
        XCTAssertTrue(
            script.contains(#"/usr/bin/open -n "${app_bundle}""#),
            "run 命令必须以 .app bundle 为启动对象"
        )
        XCTAssertFalse(script.contains(">/tmp/"), "run.sh 不得把产物日志重定向进 /tmp")
        let backgroundLaunchLines = script.split(separator: "\n").filter { line in
            line.hasSuffix(" &") || line.hasSuffix(" &)")
        }
        XCTAssertTrue(
            backgroundLaunchLines.isEmpty,
            "run.sh 不得后台启动子进程: \(backgroundLaunchLines)"
        )
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

    /// bundle 定位是 run.sh 最容易随工具链漂移的点:本机工具链产出
    /// CCSpaceTests.xctest,CI runner 工具链只产出 CCSpacePackageTests.xctest
    /// (实测绿色构建日志)。此前测试只断言 run.sh 的字面文本,完全没覆盖定位逻辑,
    /// 于是"退化路径排除 *PackageTests*"的回归只在 push 后的 CI 上暴露。
    /// 这里把 locate_test_bundle 函数体从 run.sh 原样抽出、在 bash 里真跑,
    /// 对六种 fixture 断言选择结果——查找顺序一变(尤其砍掉第三级兜底)即红;
    /// 后两种额外锁住"多候选按 LC_ALL=C 排序取第一个(不依赖 readdir 顺序)"
    /// 与"-type d 过滤同名普通文件"两条确定性语义。
    func test_runScriptLocateTestBundleSelectionAcrossToolchains() throws {
        let functionSource = try locateTestBundleFunctionSource()
        let fileManager = FileManager.default
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunScriptTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        func makeFixture(_ name: String, bundles: [String]) throws -> String {
            let dir = fixtureRoot.appendingPathComponent(name)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for bundle in bundles {
                try fileManager.createDirectory(
                    at: dir.appendingPathComponent(bundle),
                    withIntermediateDirectories: true
                )
            }
            return dir.path
        }

        // 1) 只有本机工具链产物:精确匹配命中
        let localOnly = try makeFixture("local-only", bundles: ["CCSpaceTests.xctest"])
        // 2) 只有 CI runner 工具链产物:退化路径必须放行 *PackageTests*,否则 CI 必红
        let ciOnly = try makeFixture("ci-only", bundles: ["CCSpacePackageTests.xctest"])
        // 3) 两者并存:精确匹配优先
        let both = try makeFixture(
            "both",
            bundles: ["CCSpacePackageTests.xctest", "CCSpaceTests.xctest"]
        )
        // 4) 空目录:回显空串,交给调用方给出上下文报错
        let empty = try makeFixture("empty", bundles: [])
        // 5) 多个非精确匹配 bundle 并存:必须返回 LC_ALL=C 排序后的第一个。
        //    创建顺序刻意打乱——find 的原始顺序由 readdir 决定,与创建顺序、
        //    字母序都不一致(实测为 Zulu Charlie Alpha Bravo Mike),不排序时
        //    选中谁随机器/文件系统漂移。
        let manyNonExact = try makeFixture(
            "many-non-exact",
            bundles: ["Zulu.xctest", "Charlie.xctest", "Alpha.xctest", "Bravo.xctest", "Mike.xctest"]
        )
        // 6) 名为 CCSpaceTests.xctest 的**普通文件**:-type d 必须把它过滤掉,
        //    否则 [ -e ] 通过、`xcrun xctest <file>` 只会报难懂错误。
        let fileNamed = try makeFixture("file-named", bundles: [])
        XCTAssertTrue(
            fileManager.createFile(atPath: "\(fileNamed)/CCSpaceTests.xctest", contents: nil),
            "fixture 应能创建名为 CCSpaceTests.xctest 的普通文件"
        )

        let localResult = try runLocateTestBundle(functionSource: functionSource, binPath: localOnly)
        let ciResult = try runLocateTestBundle(functionSource: functionSource, binPath: ciOnly)
        let bothResult = try runLocateTestBundle(functionSource: functionSource, binPath: both)
        let emptyResult = try runLocateTestBundle(functionSource: functionSource, binPath: empty)
        let manyResult = try runLocateTestBundle(functionSource: functionSource, binPath: manyNonExact)
        let fileResult = try runLocateTestBundle(functionSource: functionSource, binPath: fileNamed)

        XCTAssertEqual(localResult, "\(localOnly)/CCSpaceTests.xctest")
        XCTAssertEqual(
            ciResult,
            "\(ciOnly)/CCSpacePackageTests.xctest",
            "CI 上只有聚合 runner bundle,退化路径不得排除 *PackageTests*(否则 runner 全红)"
        )
        XCTAssertEqual(
            bothResult,
            "\(both)/CCSpaceTests.xctest",
            "多 bundle 并存时应优先精确匹配本包测试产物"
        )
        XCTAssertEqual(emptyResult, "", "定位不到时应回显空串,由调用方给出上下文报错")
        XCTAssertEqual(
            manyResult,
            "\(manyNonExact)/Alpha.xctest",
            "多个非精确匹配并存时应返回 LC_ALL=C 排序后的第一个,结果不得依赖 readdir 顺序"
        )
        XCTAssertEqual(
            fileResult,
            "",
            "同名普通文件不是 bundle(-type d),应回显空串而不是交给 xcrun xctest"
        )
    }

    /// 从 run.sh 抽出 locate_test_bundle 函数体(定义行到首个顶格 `}`),
    /// 抽不到说明函数被改名/移走——测试直接失败而不是静默跳过。
    private func locateTestBundleFunctionSource() throws -> String {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("run.sh"),
            encoding: .utf8
        )
        let lines = script.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("locate_test_bundle()") }) else {
            throw RunScriptTestError.locateFunctionMissing("run.sh 中找不到 locate_test_bundle 定义行")
        }
        guard let end = lines[start...].firstIndex(where: { $0 == "}" }) else {
            throw RunScriptTestError.locateFunctionMissing("locate_test_bundle 函数体没有顶格结束的 }")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// 在独立 bash 进程里 source 出函数并对 fixture 目录执行,回显其 stdout。
    private func runLocateTestBundle(functionSource: String, binPath: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // $0 只占位,$1 = 函数体,$2 = 待查找目录。
        let script = """
        set -euo pipefail
        eval "$1"
        locate_test_bundle "$2"
        """
        process.arguments = ["-c", script, "locate_test_bundle_test", functionSource, binPath]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // 先读管道再 wait,避免子进程因管道写满而卡死(输出很小,实践中不会触发)。
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw RunScriptTestError.bashFailed(process.terminationStatus, stderrText)
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}

private enum RunScriptTestError: Error, CustomStringConvertible {
    case locateFunctionMissing(String)
    case bashFailed(Int32, String)

    var description: String {
        switch self {
        case .locateFunctionMissing(let reason):
            return reason
        case .bashFailed(let status, let stderr):
            return "bash 执行失败(exit \(status)): \(stderr)"
        }
    }
}
