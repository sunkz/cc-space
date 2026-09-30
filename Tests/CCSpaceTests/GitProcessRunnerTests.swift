import XCTest
import Darwin
@testable import CCSpace

final class GitProcessRunnerTests: XCTestCase {
    func test_runGitVersionReturnsZeroExitAndStdout() async throws {
        let result = try await GitProcessRunner().run(
            arguments: ["--version"],
            captureStdout: true,
            captureStderr: true,
            timeout: 15
        )

        XCTAssertEqual(result.terminationStatus, 0)
        let stdout = String(data: result.stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("git version"))
    }

    func test_cancelledBeforeStartFailsFastWithoutHanging() async {
        let task = Task {
            try await GitProcessRunner().run(
                arguments: ["--version"],
                captureStdout: true,
                captureStderr: true,
                timeout: 15
            )
        }
        // 在 body 有机会执行前取消:入口快速失败或 onCancel 补偿恢复,都不得挂起。
        task.cancel()

        let started = Date()
        do {
            _ = try await task.value
            // 若竞态落入正常执行路径(--version 极快),结果返回也可接受。
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "启动前取消应抛 CancellationError,实际: \(error)"
            )
        }
        // 核心契约是"不挂起":远早于 15s 超时返回。
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_cancelWhileRunningThrowsCancellationErrorWithoutHanging() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sleep"), "环境缺少 sleep")

        let task = Task {
            try await GitProcessRunner().run(
                arguments: ["-c", "alias.ccspace-test-wait=!exec sleep 30", "ccspace-test-wait"],
                captureStdout: true,
                captureStderr: true,
                timeout: 60
            )
        }
        // 等待进程真正跑起来后再取消。
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("运行中取消应抛出 CancellationError")
        } catch {
            // 必须是取消,而不是被 timeout 兜底(GitProcessExecutionError.timedOut):
            // 后者说明取消根本没传到进程。
            XCTAssertTrue(
                error is CancellationError,
                "运行中取消应抛 CancellationError,实际: \(error)"
            )
        }
    }

    /// 含 NUL 字节的参数会在 argv 构造处 fatalError 崩掉整个 App,
    /// 必须在进程入口被拒绝而不是透传。
    func test_argumentsWithNULByteRejectedAtProcessEntrance() async {
        let evil = "/tmp\u{0}evil"
        do {
            _ = try await GitProcessRunner().run(
                arguments: ["-C", evil, "status"],
                captureStdout: true,
                captureStderr: true,
                timeout: 5
            )
            XCTFail("含 NUL 的参数必须被拒绝")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("非法控制字符"),
                "应抛出入参校验错误,实际: \(error.localizedDescription)"
            )
        }
    }

    /// 每条命令的两条管道(4 个 fd)必须随调用结束全部收回。
    ///
    /// 曾经的回归:DataBox → onOverflow → DrainSchedulerBox → 调度器闭包 → DataBox 构成
    /// 每次调用必现的强引用环,Process/Pipe 永不释放,fd 以"每次 git 调用 4 个"的速率
    /// 累积;数小时后耗尽上限,`process.run()` 全线失败,而上游读取用 `try?` 吞掉错误,
    /// 用户侧只剩"切回前台后仓库状态加载不出来、点刷新也没反应"。
    func test_repeatedRunsDoNotLeakFileDescriptors() async throws {
        let runner = GitProcessRunner()
        let baseline = openPipeDescriptorCount()

        for _ in 0..<20 {
            _ = try await runner.run(
                arguments: ["--version"],
                captureStdout: true,
                captureStderr: true,
                timeout: 15
            )
        }
        // 管道随排干通知释放,释放点在本次调用结束前后数毫秒内;留出这点余量只为
        // 让断言不依赖线程调度。排水兜底时限(30s)不参与:执行体在排干时已摘走。
        try await Task.sleep(for: .milliseconds(800))

        let after = openPipeDescriptorCount()
        XCTAssertLessThanOrEqual(
            after,
            baseline + 4,
            "git 调用残留未关闭的管道 fd(baseline=\(baseline) after=\(after),20 次调用共 80 个管道 fd 必须全部收回)"
        )
    }

    /// 子进程环境组装:继承来的 git 覆盖变量必须被剥掉。
    ///
    /// app 从 git shell 函数/wrapper 里启动时,GIT_DIR 这类变量会随继承进入每个
    /// git 子进程并**压过** `-C <目录>` 定位——所有仓库操作被指向启动它的那个仓库,
    /// 且因为命令"成功执行",错误完全不可归因。
    /// 测试纯函数而不是真起进程:setenv 是进程级全局状态,并行跑测时会污染同进程
    /// 的其它用例(见 ShellHelper 注释)。
    func test_childEnvironmentStripsInheritedGitOverrides() {
        let environment = GitProcessRunner.childEnvironment(
            inherited: [
                "GIT_DIR": "/someone/else/.git",
                "GIT_WORK_TREE": "/someone/else",
                "GIT_INDEX_FILE": "/someone/else/.git/index",
                "GIT_CONFIG_SYSTEM": "/someone/else/gitconfig",
                "GIT_CONFIG_COUNT": "1",
                "HOME": "/Users/tester",
            ],
            additional: ["GIT_CONFIG_GLOBAL": "/isolated/gitconfig"]
        )

        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT"] {
            XCTAssertNil(environment[key], "继承的 \(key) 必须被剥离,否则 -C 定位被劫持")
        }
        // 注入项在剥离**之后**合并:测试用的配置隔离仍然生效。
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/isolated/gitconfig")
        // 无关变量与固定项保持。
        XCTAssertEqual(environment["HOME"], "/Users/tester")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
    }

    /// 用户已有的 GIT_SSH_COMMAND 只追加 BatchMode,不整体覆盖。
    func test_childEnvironmentAppendsBatchModeToExistingSSHCommand() {
        let withUserValue = GitProcessRunner.childEnvironment(
            inherited: ["GIT_SSH_COMMAND": "ssh -i ~/.ssh/id_custom"]
        )
        XCTAssertEqual(
            withUserValue["GIT_SSH_COMMAND"],
            "ssh -i ~/.ssh/id_custom -o BatchMode=yes",
            "整体覆盖会把用户的密钥/端口配置静默丢弃"
        )

        let withoutUserValue = GitProcessRunner.childEnvironment(inherited: [:])
        XCTAssertEqual(withoutUserValue["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
    }

    /// 当前进程打开的**管道** fd 数。    ///
    /// 只数管道而不数全部 fd:XCTest 自身会陆续打开普通文件,按总 fd 数断言会把
    /// 无关增长算成泄漏。`Pipe()` 走 `pipe(2)`,fstat 形态为 S_IFIFO。
    private func openPipeDescriptorCount() -> Int {
        var statBuffer = stat()
        var count = 0
        for fd in 0..<getdtablesize() where fcntl(Int32(fd), F_GETFD) >= 0 {
            if fstat(Int32(fd), &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFIFO {
                count += 1
            }
        }
        return count
    }
}
