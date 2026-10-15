import XCTest
@testable import CCSpace

/// git 子进程执行面加固的回归锁。
///
/// 仓库自带的 `.git/config` 可以把若干配置键指到任意可执行程序,而 `git status`/
/// `git diff` 这类**只读**命令会去执行它。拷进工作区的目录会被自动纳管,纳管后每次
/// 状态刷新都跑一遍——等于"打开工作区看一眼"就执行了仓库带来的代码,全程没有用户确认。
///
/// 本文件逐键钉死封堵方式:
/// - `core.fsmonitor` → `-c` 覆盖为 false;
/// - `core.askPass` → `-c` 覆盖为空(实测空值等价未配置,不会去 exec 空命令);
/// - `diff.external` / `diff.<driver>.textconv` → 命令行开关 `--no-ext-diff
///   --no-textconv`(**不能**用 `-c diff.external=`:实测会让 git 去 exec 空命令名
///   并把整个 diff 打成 `fatal: external diff died`);
/// - `credential.helper` → `-c` 重置后再回填用户自己的 system/global 值。
final class GitProcessRunnerHardeningTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        GitService.resetForTesting()
    }

    override func tearDown() {
        GitService.resetForTesting()
        super.tearDown()
    }

    /// 每次 git 调用都必须前置 fsmonitor/askPass 关闭项(`-c` 排在子命令前才生效)。
    /// 字面量钉死:新增/删除覆盖项都必须是有意识的决定,不能让测试跟着实现漂移。
    func test_fixedGlobalConfigurationArgumentsDisableExecCapableKeys() {
        XCTAssertEqual(
            GitProcessRunner.fixedGlobalConfigurationArguments,
            ["-c", "core.fsmonitor=false", "-c", "core.askPass="]
        )
    }

    /// `diff.external` 一律不出现在 `-c` 覆盖里:实测把它覆盖成空值会让 git 认为
    /// 外部 diff 已启用并去 exec 空命令名,`git diff` 直接 fatal,diff 视图全废。
    /// 封堵靠 `--no-ext-diff --no-textconv`(见 test_diffViewerBlocksRepoCarriedTextconvDriver)。
    func test_diffExternalIsNotOverriddenByEmptyConfigValue() {
        XCTAssertFalse(
            GitProcessRunner.fixedGlobalConfigurationArguments.contains { $0.contains("diff.external") },
            "禁止用 `-c diff.external=` 封堵:空值会被当成外部 diff 程序名去 exec"
        )
    }

    /// 凭据 helper 链:先重置(清掉仓库自带 `!命令`),再原样回填用户自己的 helper。
    /// 一刀切重置会把用户的 osxkeychain 也抹掉,私有仓库当场拉不下来。
    func test_credentialGuardArgumentsResetThenRestoreUserHelpers() {
        // 没有任何用户 helper:只下发重置。
        XCTAssertEqual(
            GitProcessRunner.credentialGuardArguments(userHelpers: []),
            ["-c", "credential.helper="]
        )
        // 有用户 helper:重置在前,回填按声明顺序跟在后面(-c 值按出现顺序构成链)。
        XCTAssertEqual(
            GitProcessRunner.credentialGuardArguments(userHelpers: ["osxkeychain", "store"]),
            [
                "-c", "credential.helper=",
                "-c", "credential.helper=osxkeychain",
                "-c", "credential.helper=store",
            ]
        )
        // 空行/空白值不进 argv:会拼出一条无意义的 `credential.helper=` 二次重置。
        XCTAssertEqual(
            GitProcessRunner.credentialGuardArguments(userHelpers: ["  ", "", "osxkeychain"]),
            ["-c", "credential.helper=", "-c", "credential.helper=osxkeychain"]
        )
    }

    /// 组装顺序:固定安全项在前,凭据链覆盖在后(重置必须先于回填成立)。
    func test_globalConfigurationArgumentsOrderFixedBeforeCredentialGuard() {
        let arguments = GitProcessRunner.globalConfigurationArguments(userHelpers: ["osxkeychain"])
        XCTAssertEqual(
            arguments,
            GitProcessRunner.fixedGlobalConfigurationArguments
                + GitProcessRunner.credentialGuardArguments(userHelpers: ["osxkeychain"])
        )
        XCTAssertEqual(arguments.prefix(2).map { $0 }, ["-c", "core.fsmonitor=false"])
    }

    /// `git config --get-all` 输出的按行拆分:尾换行/空行不得变成一条空 helper。
    func test_decodedConfigLinesSplitsAndDropsBlanks() {
        let data = Data("osxkeychain\n\nstore\n".utf8)
        XCTAssertEqual(GitProcessRunner.decodedConfigLines(data), ["osxkeychain", "store"])
        XCTAssertEqual(GitProcessRunner.decodedConfigLines(Data()), [])
    }

    /// 继承环境里"指向可执行程序"的键必须被剥掉;而属用户信任域的 askpass 环境变量
    /// 刻意保留——仓库无法写入进程环境,剥掉只会削掉用户自己的认证能力。
    func test_childEnvironmentStripsProgramPointingKeysAndKeepsUserAskpass() {
        let environment = GitProcessRunner.childEnvironment(
            inherited: [
                "GIT_EXTERNAL_DIFF": "/tmp/evil-diff",
                "GIT_PATCH_COMMAND": "/tmp/evil-patch",
                "GIT_PROXY_COMMAND": "/tmp/evil-proxy",
                "GIT_CONFIG_PARAMETERS": "-c core.fsmonitor=\"/tmp/evil-fsmonitor\"",
                "GIT_ASKPASS": "/Applications/SomeEditor/app/extensions/git/assets/scripts/askpass.sh",
                "SSH_ASKPASS": "/tmp/user-askpass",
                "PATH": "/usr/bin",
            ]
        )
        XCTAssertNil(environment["GIT_EXTERNAL_DIFF"])
        XCTAssertNil(environment["GIT_PATCH_COMMAND"], "GIT_PATCH_COMMAND 是 EXTERNAL_DIFF 的配套程序名")
        XCTAssertNil(environment["GIT_PROXY_COMMAND"])
        XCTAssertNil(environment["GIT_CONFIG_PARAMETERS"])
        XCTAssertEqual(
            environment["GIT_ASKPASS"],
            "/Applications/SomeEditor/app/extensions/git/assets/scripts/askpass.sh",
            "askpass 环境变量属用户信任域,剥它不缩小攻击面、只破坏用户认证"
        )
        XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/user-askpass")
    }

    /// 端到端:首次取数会缓存用户 helper,组装出的前置参数必须带重置项,
    /// 且重置出现在任何回填之前。
    func test_resolvedGlobalConfigurationArgumentsAlwaysCarriesCredentialReset() async {
        let arguments = await GitProcessRunner.resolvedGlobalConfigurationArguments()
        XCTAssertTrue(
            arguments.contains("credential.helper="),
            "凭据 helper 链未被重置,仓库自带的 `!命令` helper 仍会参与认证"
        )
        guard let resetIndex = arguments.firstIndex(of: "credential.helper=") else { return }
        let reAddIndexes = arguments.enumerated().compactMap { index, value -> Int? in
            value.hasPrefix("credential.helper=") && value != "credential.helper=" ? index : nil
        }
        XCTAssertTrue(
            reAddIndexes.allSatisfy { $0 > resetIndex },
            "回填必须排在重置之后,否则会被自己清空"
        )
    }

    private static func git(_ arguments: [String]) throws {
        let result = try ShellHelper.run(["git"] + arguments)
        XCTAssertEqual(
            result.terminationStatus,
            0,
            "git \(arguments.joined(separator: " ")) 失败：\(result.combinedOutput)"
        )
    }

    /// 端到端:只读状态探针不得执行仓库自带的 fsmonitor 脚本。
    func test_branchStatusProbeDoesNotExecuteRepoCarriedFsmonitorHook() async throws {
        let root = makeTestRootURL()
        let repositoryURL = root.appendingPathComponent("repo")
        let hookURL = root.appendingPathComponent("hook.sh")
        let markerURL = root.appendingPathComponent("EXECUTED")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        touch '\(markerURL.path)'
        """.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        try Self.git(["-C", repositoryURL.path, "init", "-q", "."])
        try "a\n".write(to: repositoryURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.git(["-C", repositoryURL.path, "add", "a.txt"])
        try Self.git([
            "-C", repositoryURL.path, "-c", "user.email=test@example.com", "-c", "user.name=test",
            "commit", "-qm", "init",
        ])
        // 脚本挂在最后一次操作上:前面的 init/commit 不应触发它。
        try Self.git(["-C", repositoryURL.path, "config", "core.fsmonitor", hookURL.path])

        _ = await GitService().branchStatus(in: repositoryURL.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "只读探针执行了仓库自带的 core.fsmonitor 脚本"
        )
    }

    /// 端到端:diff 视图不得执行仓库自带的 textconv 驱动程序。
    ///
    /// 威胁形态:`.gitattributes` 把某类文件指到自定义 diff driver,`.git/config` 里
    /// `diff.<driver>.textconv` 写一条命令——`git diff --numstat -p` 会真的执行它
    /// (实测成立)。工作区刷新与打开 diff 窗口都会跑这条命令。
    ///
    /// 同时断言 diff 结果非空:封堵如果靠"让 diff 失败"来实现,本测试要红——
    /// 否则实现退化成 `fatal: external diff died` 也照样"没执行脚本"而假绿。
    func test_diffViewerDoesNotExecuteRepoCarriedTextconvDriver() async throws {
        let root = makeTestRootURL()
        let repositoryURL = root.appendingPathComponent("repo")
        let markerURL = root.appendingPathComponent("TEXTCONV_RAN")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        try Self.git(["-C", repositoryURL.path, "init", "-q", "."])
        try "a\n".write(to: repositoryURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.git(["-C", repositoryURL.path, "add", "a.txt"])
        try Self.git([
            "-C", repositoryURL.path, "-c", "user.email=test@example.com", "-c", "user.name=test",
            "commit", "-qm", "init",
        ])
        // 仓库自带:所有 .txt 走自定义 diff driver,driver 的 textconv 会留下执行痕迹。
        try "*.txt diff=evil\n".write(
            to: repositoryURL.appendingPathComponent(".gitattributes"),
            atomically: true, encoding: .utf8
        )
        try Self.git(["-C", repositoryURL.path, "add", ".gitattributes"])
        try Self.git([
            "-C", repositoryURL.path, "-c", "user.email=test@example.com", "-c", "user.name=test",
            "commit", "-qm", "attributes",
        ])
        try Self.git([
            "-C", repositoryURL.path, "config", "diff.evil.textconv",
            "sh -c 'touch \(markerURL.path); cat'",
        ])
        try "b\n".write(to: repositoryURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let entries = try await GitService().diffWorkingDirectory(in: repositoryURL.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "diff 视图执行了仓库自带的 diff.<driver>.textconv 命令"
        )
        XCTAssertTrue(
            entries.contains { $0.filePath == "a.txt" },
            "封堵把正常 diff 一起打死了(应带 --no-ext-diff/--no-textconv,而不是让 git 报错)"
        )
    }

    /// 端到端:仓库自带的 `diff.external` 同样不得被执行(靠 `--no-ext-diff` 拦住)。
    func test_diffViewerDoesNotExecuteRepoCarriedExternalDiff() async throws {
        let root = makeTestRootURL()
        let repositoryURL = root.appendingPathComponent("repo")
        let markerURL = root.appendingPathComponent("EXTDIFF_RAN")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        try Self.git(["-C", repositoryURL.path, "init", "-q", "."])
        try "a\n".write(to: repositoryURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.git(["-C", repositoryURL.path, "add", "a.txt"])
        try Self.git([
            "-C", repositoryURL.path, "-c", "user.email=test@example.com", "-c", "user.name=test",
            "commit", "-qm", "init",
        ])
        try Self.git([
            "-C", repositoryURL.path, "config", "diff.external",
            "sh -c 'touch \(markerURL.path); true'",
        ])
        try "b\n".write(to: repositoryURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let entries = try await GitService().diffWorkingDirectory(in: repositoryURL.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "diff 视图执行了仓库自带的 diff.external 程序"
        )
        XCTAssertFalse(entries.isEmpty, "外部 diff 封堵不应让 diff 结果为空")
    }
}
