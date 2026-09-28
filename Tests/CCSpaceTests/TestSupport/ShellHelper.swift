import Foundation

/// 外部命令执行结果：stdout/stderr 分路保留，退出码一并带回。
struct ShellResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32

    /// stdout 与 stderr 的拼接（stderr 追加在后，不还原两路的交错时序）。
    /// 仅用于失败诊断或"输出里应含某子串"这类宽松断言，不要拿它做精确相等比较。
    var combinedOutput: String { stdout + stderr }
}

/// 测试内驱动 `/usr/bin/git` 的**唯一**实现。
///
/// 此前 `GitServiceTests` 与 `GitServicePullAllBranchesTests` 各持一份 shell()
/// 实现，其中 GitServiceTests 的版本先 `readDataToEndOfFile(stdoutPipe)` 阻塞到
/// EOF 再去读 stderr：子进程往 stderr 写满 64KB 管道缓冲后会阻塞在写端永不退出，
/// stdout 也就永远等不到 EOF，测试**永久挂起**（CI 拖满超时）。
///
/// 这里统一为两路管道并发排水（各自的 `readabilityHandler` 在 EOF 时自摘除并放行）：
/// 任何一路先排空都不会被另一路的高水位拖死，也消除了两份实现漂移的可能。
enum ShellHelper {
    /// 执行 `/usr/bin/git`，剥掉调用方习惯传入的首参 `"git"` 字面量，
    /// 并注入与生产同款的配置隔离（gpgsign 弹签名、hooksPath 执行用户脚本等）。
    ///
    /// - Parameters:
    ///   - arguments: git 参数，形如 `["git", "-C", path, "status"]`；
    ///     首参不是 `"git"` 时按原样作为 git 的参数传递。
    ///   - environment: 额外注入**子进程**的环境变量（按用例覆盖，如
    ///     `GIT_CONFIG_GLOBAL` 配置隔离）。nil 时完全继承测试进程环境。
    ///     用显式 environment 而不是 setenv：后者是进程级全局状态，
    ///     XCTest 并行模式下会让同进程的其它用例互相覆盖。
    static func run(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ShellResult {
        // 固定系统 git：经 /usr/bin/env 解析会吃进 PATH 里的同名遮蔽品。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // executableURL 已固定为系统 git，调用方习惯传入的首个 "git" 字面量必须剥掉，
        // 否则会作为子命令传给 git 本身（git: 'git' is not a git command）。
        let gitIsolationArguments = [
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
        ]
        process.arguments = arguments.first == "git"
            ? gitIsolationArguments + Array(arguments.dropFirst())
            : arguments
        if let environment, environment.isEmpty == false {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment
            ) { _, injected in injected }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 先启动两路排水再等退出：若先 waitUntilExit，输出超过 64KB 管道缓冲时
        // 子进程阻塞在写端、我们阻塞在 wait，互相死锁。
        let stdoutBox = ShellDataBox()
        let stderrBox = ShellDataBox()
        let drainGroup = DispatchGroup()
        drain(stdoutPipe, into: stdoutBox, group: drainGroup)
        drain(stderrPipe, into: stderrBox, group: drainGroup)
        drainGroup.wait()
        process.waitUntilExit()

        return ShellResult(
            stdout: stdoutBox.stringValue,
            stderr: stderrBox.stringValue,
            terminationStatus: process.terminationStatus
        )
    }

    /// 用 readabilityHandler 增量排空单路管道：EOF 时 availableData 为空，
    /// 回调自摘除并放行 drainGroup。两路各自独立，互不拖累。
    private static func drain(_ pipe: Pipe, into box: ShellDataBox, group: DispatchGroup) {
        group.enter()
        // EOF 回调可能被投递两次：裸 group.leave() 重复调用会让 DispatchGroup
        // over-leave 直接崩掉测试进程，这里走「恰好一次」终结器
        // （同生产侧 GitProcessRunner.ReadFinalizer 的写法）。
        let finalizer = DrainGroupFinalizer(group: group)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard chunk.isEmpty == false else {
                handle.readabilityHandler = nil
                finalizer.finalize()
                return
            }
            box.append(chunk)
        }
    }
}

/// 一条管道对 drainGroup 的「恰好一次」终结器：先到者负责 leave，后到者空操作，
/// 保证组恒平衡。
private final class DrainGroupFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let group: DispatchGroup

    init(group: DispatchGroup) {
        self.group = group
    }

    func finalize() {
        lock.lock()
        let shouldLeave = done == false
        done = true
        lock.unlock()
        if shouldLeave {
            group.leave()
        }
    }
}

/// 跨线程汇总单路管道输出（readabilityHandler 回调线程写、调用线程在
/// drainGroup.wait() 之后读，仍以锁保证 happens-before 明确）。
private final class ShellDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
