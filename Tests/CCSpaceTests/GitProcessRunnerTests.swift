import XCTest
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

}
