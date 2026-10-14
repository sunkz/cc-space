import XCTest
import Darwin
@testable import CCSpace

/// 单流输出上限(默认 64 MB)与 SIGTERM→SIGKILL 升级此前**零测试覆盖**:
/// 两条链路的判定关键字(`outputLimitExceeded`、`SIGKILL`)在 Tests 内 grep 无命中。
///
/// 两者都靠"必须终止进程"兜住严重后果,退化后表现都不易复现:
/// - 截断/溢出回调失效 → 超大 `git diff` 在超时兜底生效前先把内存耗尽(可能被 OOM 杀掉);
/// - 升级失效 → 吞掉 SIGTERM 的挂起 git(等锁、D 状态 IO)长期持有 index.lock,工作区被锁死。
final class GitProcessRunnerOutputLimitTests: XCTestCase {

    // MARK: - 单流输出上限全链路

    /// 上限压到 1 KB,驱动一条**无限输出**的 git 子命令(alias 走 shell):
    /// 截断 → 恰好一次 onOverflow → 终止进程 → 抛 outputLimitExceeded。
    ///
    /// 输出刻意无限:命令自身不会结束,只有"真的杀掉了进程"才能让本次调用返回。
    /// 若终止失效,错误仍会是 outputLimitExceeded(认领已在溢出路径取走),但会一直
    /// 等到 60s 超时兜底才返回——因此额外断言秒级返回,把"终止"这件事变成可观测契约。
    func test_outputLimitExceededTerminatesProcessAndFailsFast() async throws {
        let started = Date()
        do {
            _ = try await GitProcessRunner().run(
                arguments: [
                    "-c",
                    "alias.ccspace-output-limit=!yes ccspspace-overflow-payload",
                    "ccspace-output-limit",
                ],
                captureStdout: true,
                captureStderr: true,
                timeout: 60,
                outputLimitBytes: 1024
            )
            XCTFail("超过单流输出上限必须失败")
        } catch {
            guard case .outputLimitExceeded(let command)? = error as? GitProcessExecutionError else {
                return XCTFail("应抛 outputLimitExceeded,实际: \(error)")
            }
            // 命令描述必须带 git 前缀与子命令:错误文案是用户唯一能定位到"哪条命令炸了"的线索。
            XCTAssertTrue(command.hasPrefix("git -c"), "命令描述应带 git 前缀: \(command)")
            XCTAssertTrue(command.contains("ccspace-output-limit"), "命令描述应含子命令: \(command)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            20,
            "超限路径必须自己终止进程,不得退化成等 60s 超时兜底"
        )
    }

    /// 截断与"恰好一次溢出回调"是 `SendableDataBox` 的核心契约,直接驱动它而非赌进程时序:
    /// - 未触及上限不得回调(否则正常的大输出也会被误判为超限);
    /// - 越限 chunk 只保留到恰好上限(截断),不得整块丢弃或整块写入;
    /// - 截断后的追加全部丢弃,回调仍恰好一次——stdout/stderr 两个 box 共用同一个
    ///   处理闭包,重复触发会重复 terminate/重复恢复续体。
    func test_dataBoxTruncatesAtLimitAndNotifiesOverflowExactlyOnce() {
        let counter = OverflowCounter()
        let box = SendableDataBox(maxBytes: 8, onOverflow: { counter.increment() })

        box.append(Data(repeating: 0x41, count: 5))
        XCTAssertEqual(box.data.count, 5)
        XCTAssertEqual(counter.value, 0, "未越过上限不得触发溢出回调")

        // 第二个 chunk 越过上限:只追加到恰好 8 字节。
        box.append(Data(repeating: 0x42, count: 5))
        XCTAssertEqual(box.data.count, 8, "越限 chunk 应截断到恰好上限")
        XCTAssertEqual(counter.value, 1)

        for _ in 0..<20 {
            box.append(Data(repeating: 0x43, count: 1024))
        }
        XCTAssertEqual(box.data.count, 8, "截断后的追加必须全部丢弃,否则内存仍会涨")
        XCTAssertEqual(counter.value, 1, "溢出回调必须恰好一次")
    }

    /// 同一契约的并发面:两个管道各由独立线程的 readabilityHandler 追加,
    /// `_overflowNotified` 的读写必须靠锁串行化,否则两侧会同时判定"我先到"而双触发。
    func test_dataBoxNotifiesOverflowExactlyOnceUnderConcurrentAppends() async {
        let counter = OverflowCounter()
        let box = SendableDataBox(maxBytes: 1024, onOverflow: { counter.increment() })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<64 {
                        box.append(Data(repeating: 0x41, count: 256))
                    }
                }
            }
        }

        XCTAssertEqual(counter.value, 1, "并发追加下溢出回调必须恰好一次")
        XCTAssertLessThanOrEqual(box.data.count, 1024, "任何并发交错都不得突破硬上限")
    }

    // MARK: - SIGTERM → SIGKILL 升级

    /// 挂起的 git(等锁、D 状态 IO)可能吞掉 SIGTERM;升级路径必须在 `escalationDelay`
    /// 后以 SIGKILL 收尾——终止信号本身是断言点(`.uncaughtSignal` + `SIGKILL`),
    /// 只断言"进程没了"会把"根本没杀、自己退出了"也算通过。
    func test_scheduleSIGKILLEscalationKillsLingeringProcessWithSIGKILL() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/bin/sleep"),
            "环境缺少 /bin/sleep"
        )

        let process = try startSleeper()
        GitProcessRunner.scheduleSIGKILLEscalation(
            processBox: SendableProcessBox(process),
            escalationDelay: 0.2
        )

        try await waitForExit(process, timeout: 10)
        XCTAssertFalse(process.isRunning, "升级路径必须终止进程")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL, "必须是 SIGKILL,而不是 SIGTERM")
    }

    /// 升级回调里的 isRunning 复查是防"向已回收 pid 补刀"的唯一屏障
    /// (pid 被系统复用后会误杀无关进程)。进程早已退出时调度升级必须是无害空操作。
    func test_scheduleSIGKILLEscalationIsNoOpForAlreadyExitedProcess() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/bin/sleep"),
            "环境缺少 /bin/sleep"
        )

        let process = try startSleeper()
        process.terminate()
        try await waitForExit(process, timeout: 10)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)

        GitProcessRunner.scheduleSIGKILLEscalation(
            processBox: SendableProcessBox(process),
            escalationDelay: 0.05
        )
        // 复查失败则 kill 会作用在已回收的 pid 上:本用例只能断言"未崩溃且状态未被改写"。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    // MARK: - 辅助

    private func startSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// 轮询等待退出后再 `waitUntilExit`:未退出时读 terminationStatus 属未定义行为。
    private func waitForExit(_ process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning, "进程在 \(timeout)s 内未退出")
        process.waitUntilExit()
    }
}

/// 溢出回调计数盒:回调由 readabilityHandler 的线程调用,必须锁保护。
private final class OverflowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
