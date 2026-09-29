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

    /// 当前进程打开的**管道** fd 数。
    ///
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
