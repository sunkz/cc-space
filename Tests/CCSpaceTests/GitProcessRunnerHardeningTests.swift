import XCTest
@testable import CCSpace

/// git 子进程执行面加固的回归锁。
///
/// 仓库自带的 `.git/config` 可以把 `core.fsmonitor` 指到任意脚本,而 `git status`
/// 这类**只读**命令会去执行它。拷进工作区的目录会被自动纳管,纳管后每次状态刷新
/// 都跑一遍——等于"打开工作区看一眼"就执行了仓库带来的代码,全程没有用户确认。
final class GitProcessRunnerHardeningTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        GitService.resetForTesting()
    }

    override func tearDown() {
        GitService.resetForTesting()
        super.tearDown()
    }

    /// 每次 git 调用都必须前置 fsmonitor 关闭项(`-c` 排在子命令前才生效)。
    func test_globalConfigurationArgumentsDisableFsmonitor() {
        XCTAssertEqual(GitProcessRunner.globalConfigurationArguments, ["-c", "core.fsmonitor=false"])
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
}
