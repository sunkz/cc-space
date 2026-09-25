import XCTest
@testable import CCSpace

final class GitProcessRunnerCancellationTests: XCTestCase {
    /// 用一个确定性的本地慢 git 命令替代真实网络克隆。
    ///
    /// 此前连 `https://192.0.2.1/...`:既依赖真实网络栈,又隐含假设"连不上至少要
    /// 0.5s"——无外网时 git 会立刻以非零码退出,run 正常返回而非超时,用例直接
    /// XCTFail(实打实的 flaky)。alias + sleep 完全离线且时长可控。
    private static let slowCommand: [String] = [
        // exec 让 sleep 直接替换 sh -c 的 shell 进程:runner terminate 的是 git(exec 后
        // 即 sleep 本身),否则杀掉的是 shell、sleep 成为孤儿继续跑满 30s,反复运行堆积。
        "-c", "alias.ccspace-test-wait=!exec sleep 30", "ccspace-test-wait"
    ]

    func test_cancellingTaskCompletes() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sleep"), "环境缺少 sleep")

        let runner = GitProcessRunner()
        let started = Date()
        // 先落为局部变量再进 Task:CI 稳定版工具链对「Task 闭包内引用类的
        // static 属性」的区域隔离检查报错(编译器已知缺陷),本地快照避开该模式。
        let slowCommand = Self.slowCommand
        let task = Task {
            try await runner.run(
                arguments: slowCommand,
                captureStdout: true,
                captureStderr: true,
                timeout: 60
            )
        }

        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应正常返回")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "取消应抛 CancellationError,实际: \(error)"
            )
        }
        // "快速失败"是这里的真契约:必须在 30s sleep 结束前返回。
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func test_timeoutProducesTimedOutError() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sleep"), "环境缺少 sleep")

        let runner = GitProcessRunner()
        do {
            _ = try await runner.run(
                arguments: Self.slowCommand,
                captureStdout: true,
                captureStderr: true,
                timeout: 0.5
            )
            XCTFail("Expected timeout error")
        } catch let error as GitProcessExecutionError {
            if case .timedOut(let command, _) = error {
                XCTAssertTrue(command.contains("ccspace-test-wait"))
            } else {
                XCTFail("Expected timedOut error case, got \(error)")
            }
        }
    }

    func test_normalCompletionReturnsResult() async throws {
        let runner = GitProcessRunner()

        let result = try await runner.run(
            arguments: ["--version"],
            captureStdout: true,
            captureStderr: false,
            timeout: 10
        )

        XCTAssertEqual(result.terminationStatus, 0)
        let output = String(data: result.stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("git version"))
    }

    func test_failedCommandReturnsNonZeroStatus() async throws {
        let runner = GitProcessRunner()

        let result = try await runner.run(
            arguments: ["log", "--oneline", "-1"],
            captureStdout: true,
            captureStderr: true,
            timeout: 10
        )

        // Running in /tmp which isn't a git repo — should fail
        XCTAssertNotEqual(result.terminationStatus, 0)
        let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("not a git repository") || stderr.contains("fatal"))
    }
}
