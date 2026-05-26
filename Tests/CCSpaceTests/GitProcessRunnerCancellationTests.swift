import XCTest
@testable import CCSpace

final class GitProcessRunnerCancellationTests: XCTestCase {
    func test_cancellingTaskCompletes() async throws {
        let runner = GitProcessRunner()
        let destPath = NSTemporaryDirectory() + "ccspace-cancel-test-\(UUID().uuidString)"

        let task = Task {
            try await runner.run(
                arguments: ["clone", "https://192.0.2.1/nonexistent.git", destPath],
                captureStdout: true,
                captureStderr: true,
                timeout: 30
            )
        }

        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || error is GitProcessExecutionError,
                "Unexpected error type: \(error)"
            )
        }
    }

    func test_timeoutProducesTimedOutError() async throws {
        let runner = GitProcessRunner()
        let destPath = NSTemporaryDirectory() + "ccspace-timeout-test-\(UUID().uuidString)"

        do {
            _ = try await runner.run(
                arguments: ["clone", "https://192.0.2.1/nonexistent.git", destPath],
                captureStdout: true,
                captureStderr: true,
                timeout: 0.5
            )
            XCTFail("Expected timeout error")
        } catch let error as GitProcessExecutionError {
            if case .timedOut(let command, _) = error {
                XCTAssertTrue(command.contains("clone"))
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
