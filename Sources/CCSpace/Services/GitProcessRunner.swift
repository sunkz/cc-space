import Foundation
import ObjCExceptionCatch

struct GitProcessResult {
    let terminationStatus: Int32
    let stdoutData: Data
    let stderrData: Data
}

enum GitProcessExecutionError: LocalizedError, Equatable {
    case timedOut(command: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command, let timeout):
            return "操作超时（\(Int(timeout))s），仓库可能过大或网络连接过慢：\(command)"
        }
    }
}

struct GitProcessRunner {
    private static let gitURL: URL? = {
        let candidates = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

    /// 探测到的 git 可执行文件路径(设置页诊断展示用);找不到任何候选时为 nil。
    static var gitExecutablePath: String? {
        gitURL?.path
    }

    func run(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60
    ) async throws -> GitProcessResult {
        guard let gitURL = Self.gitURL else {
            throw NSError(
                domain: "GitProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 git 可执行文件"]
            )
        }
        // 已取消的任务直接快速失败,避免无谓启动进程,
        // 也规避 onCancel 先于 body 执行的时序。
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        // 安全兜底:只放行白名单传输协议。git 对用户直接发起的命令默认允许 ext::
        // 等可执行任意命令的传输形式,用户配置的远端 URL 会原样进入 argv;
        // Service 层入口另有 URL 校验(GitURLParser.validateRemoteURL),这里双保险。
        environment["GIT_ALLOW_PROTOCOL"] = "https:http:ssh:git:file"
        process.environment = environment

        let stdoutPipe = captureStdout ? Pipe() : nil
        let stderrPipe = captureStderr ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        process.standardError = stderrPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let processBox = SendableProcessBox(process)
        let continuationClaim = ContinuationClaimBox()
        let commandDescription = Self.safeCommandDescription(arguments: arguments)
        // 排水兑底的调度器在 continuation 闭包体内定义,onCancel 需要在取消路径
        // 复用它(见 onCancel 注释),经 box 中转。onCancel 先于 body 存入时为 nil,
        // 此时进程未启动,body 自己的失败清理路径会摘 handler。
        let drainSchedulerBox = DrainSchedulerBox()

        let continuationBox = SendableContinuationBox<GitProcessResult>()
        // 进程退出后,管道读端可能被子进程(如 ssh)继续持有,EOF 迟迟不来;
        // 超时定时器在正常退出路径已被取消,因此排水本身也需要兜底时限。
        let drainFallbackInterval: TimeInterval = 30

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.store(continuation)

                let stdoutBox = SendableDataBox()
                let stderrBox = SendableDataBox()
                let readGroup = DispatchGroup()
                // 每管道恰好一次的 group leave 终结器:EOF 与"摘除回调但 EOF 永不到来"
                // 的兜底路径(排水超时/启动失败)共用,保证 readGroup 恒平衡——
                // 否则 notify 闭包(捕获 Pipe/box)与 fd 引用永久滞留。
                let stdoutRead = ReadFinalizer(group: readGroup)
                let stderrRead = ReadFinalizer(group: readGroup)

                // 用 readabilityHandler 增量读取,不用阻塞式 readDataToEndOfFile:
                // 阻塞读期间从其他线程 closeFile 属未定义行为(FileHandle 可能在
                // 后台队列抛 ObjC 异常直接崩进程)。handler 在 EOF 时自摘除,
                // fd 由 Pipe 释放引用后在 deinit 关闭,任何路径都不需要强制 close。
                if let pipe = stdoutPipe {
                    readGroup.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard chunk.isEmpty == false else {
                            handle.readabilityHandler = nil
                            stdoutRead.finalize()
                            return
                        }
                        stdoutBox.append(chunk)
                    }
                }

                if let pipe = stderrPipe {
                    readGroup.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard chunk.isEmpty == false else {
                            handle.readabilityHandler = nil
                            stderrRead.finalize()
                            return
                        }
                        stderrBox.append(chunk)
                    }
                }

                /// 排水兜底:进程退出后管道读端可能被残留子进程(如 ssh)持有,EOF 迟迟不来。
                /// 兜底超时后摘除读回调并以已有数据恢复续体;正常排水完成时会取消兜底,
                /// continuationBox 的 resume 幂等,双恢复安全。
                /// isTimeoutPath:本次兜底由超时路径调度时置位——即使管道排干失败,
                /// 也必须恢复为超时错误而不是"被 SIGTERM 的退出码 + 半截输出"的伪成功。
                nonisolated(unsafe) let scheduleDrainFallback: (Bool, @escaping @Sendable () -> Void) -> Void = { isTimeoutPath, resume in
                    nonisolated(unsafe) let drainFallbackWork = DispatchWorkItem { [processBox, continuationBox, stdoutRead, stderrRead] in
                        // 只摘除读回调,不 closeFile:与回调执行竞态的 close 属未定义行为;
                        // 引用释放后 Pipe 在 deinit 中关闭 fd。
                        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                        stderrPipe?.fileHandleForReading.readabilityHandler = nil
                        // EOF 永不到来,补偿性 leave(与 EOF 路径互斥,恰好一次)让 notify 落地。
                        if stdoutPipe != nil { stdoutRead.finalize() }
                        if stderrPipe != nil { stderrRead.finalize() }
                        if isTimeoutPath {
                            if processBox.process.isRunning {
                                // SIGTERM 被忽略:升级为 SIGKILL,避免残留 git 进程
                                // 长期持有工作区(如 index.lock)。
                                kill(processBox.process.processIdentifier, SIGKILL)
                            }
                            continuationBox.resume(
                                throwing: GitProcessExecutionError.timedOut(
                                    command: commandDescription,
                                    timeout: timeout
                                )
                            )
                            return
                        }
                        guard processBox.process.isRunning == false else {
                            // 进程未退出时读 terminationStatus 属未定义行为,按超时处理。
                            continuationBox.resume(
                                throwing: GitProcessExecutionError.timedOut(
                                    command: commandDescription,
                                    timeout: timeout
                                )
                            )
                            return
                        }
                        continuationBox.resume(
                            returning: GitProcessResult(
                                terminationStatus: processBox.process.terminationStatus,
                                stdoutData: stdoutBox.data,
                                stderrData: stderrBox.data
                            )
                        )
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + drainFallbackInterval,
                        execute: drainFallbackWork
                    )
                    readGroup.notify(queue: .global()) {
                        drainFallbackWork.cancel()
                        resume()
                    }
                }
                drainSchedulerBox.scheduler = scheduleDrainFallback

                nonisolated(unsafe) let timeoutWork = DispatchWorkItem { [processBox, continuationClaim] in
                    guard processBox.process.isRunning else { return }
                    guard continuationClaim.claim() else { return }
                    processBox.process.terminate()
                    scheduleDrainFallback(true) {
                        continuationBox.resume(
                            throwing: GitProcessExecutionError.timedOut(
                                command: commandDescription,
                                timeout: timeout
                            )
                        )
                    }
                }

                process.terminationHandler = { completedProcess in
                    timeoutWork.cancel()
                    guard continuationClaim.claim() else { return }
                    scheduleDrainFallback(false) {
                        continuationBox.resume(
                            returning: GitProcessResult(
                                terminationStatus: completedProcess.terminationStatus,
                                stdoutData: stdoutBox.data,
                                stderrData: stderrBox.data
                            )
                        )
                    }
                }

                do {
                    // 启动前再检查一次取消:
                    // withTaskCancellationHandler 的 onCancel 可能在 body 执行到此处之前
                    // 就已触发——那时续体已被恢复(快速失败),但 body 是同步闭包,
                    // 仍会继续往下把进程真正跑起来。结果是用户点了取消,git clone
                    // (timeout 600s)仍在后台下载并写目录。
                    try Task.checkCancellation()

                    var launchException: NSException?
                    var swiftError: (any Error)?
                    let launched = ObjCExceptionCatchTryRun({
                        do {
                            try process.run()
                        } catch {
                            swiftError = error
                        }
                    }, &launchException)
                    if let swiftError {
                        throw swiftError
                    }
                    if !launched || !process.isRunning {
                        let message = launchException?.reason ?? "进程启动失败"
                        throw NSError(
                            domain: "GitProcessRunner",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    // run() 与前置取消检查之间仍有窗口:onCancel 可能恰在此间触发,
                    // 进程被启动却无人 terminate(续体已被取消路径恢复,主 body 继续跑完)。
                    // 启动成功后再判一次,发现取消立即终止,只浪费一次 fork 而非整条命令。
                    if Task.isCancelled {
                        process.terminationHandler = nil
                        process.terminate()
                        throw CancellationError()
                    }
                } catch {
                    process.terminationHandler = nil
                    timeoutWork.cancel()
                    // 摘除回调与平衡 group 必须无条件执行:若放在 claim 成功分支内,
                    // onCancel 已抢先取走 claim 时直接 return,readabilityHandler
                    // 永不移除——进程从未启动、EOF 永不到来,Pipe/fd 与捕获闭包永久泄漏。
                    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                    stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    // 同步平衡 group(当前无 notify 等待,保持组状态干净)。
                    if stdoutPipe != nil { stdoutRead.finalize() }
                    if stderrPipe != nil { stderrRead.finalize() }
                    guard continuationClaim.claim() else { return }
                    continuationBox.resume(throwing: error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
            // 不 closeFile:读端由 readabilityHandler 在 EOF 时自摘除
            // (terminate 后 git 退出、写端关闭),强制 close 与回调执行竞态属未定义行为。
            // 续体立即以 CancellationError 恢复,不依赖排水完成。
            if continuationClaim.claim() {
                // 续体可能尚未 store(onCancel 先于 body 执行的时序):
                // cancel() 会记录待取消标记,后续 store() 立即以 CancellationError 恢复。
                continuationBox.cancel()
                // 被杀的 git 可能有孙进程(如 ssh 转发)继续持有管道写端,EOF 永不到来,
                // readabilityHandler 与 readGroup.notify 捕获链随之永久滞留(fd 泄漏)。
                // 借排水兑底完成"摘 handler + 平衡 group":续体已被取消,
                // 兑底路径里的 resume 是幂等空操作,只利用其清理副作用。
                // 调度器尚未存入(取消早于 body)时进程未启动,body 自身的
                // 启动失败清理路径会摘 handler,无需此处处理。
                if let scheduler = drainSchedulerBox.scheduler {
                    scheduler(false, {})
                }
            }
        }
    }

    private static func safeCommandDescription(arguments: [String]) -> String {
        (["git"] + arguments)
            .map(redactedArgument)
            .joined(separator: " ")
    }

    private static func redactedArgument(_ argument: String) -> String {
        guard var components = URLComponents(string: argument),
              components.user != nil || components.password != nil else {
            return argument
        }

        components.user = "redacted"
        components.password = nil
        return components.string ?? "<redacted-url>"
    }
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class SendableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }

    func append(_ chunk: Data) {
        lock.lock()
        _data.append(chunk)
        lock.unlock()
    }
}

/// 一条管道对 readGroup 的"恰好一次"终结器:EOF 回调与摘除回调的兜底路径共用,
/// 先到者负责 leave,后到者空操作,保证组恒平衡且 notify 捕获链及时释放。
private struct ReadFinalizer: Sendable {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func setOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    let group: DispatchGroup
    private let flag = Flag()

    func finalize() {
        if flag.setOnce() {
            group.leave()
        }
    }
}

/// 排水兑底调度器的转发盒:onCancel 在 continuation 闭包体外,无法直接捕获
/// 体内定义的 scheduleDrainFallback,经此类中转(body 存入、onCancel 读取)。
private final class DrainSchedulerBox: @unchecked Sendable {
    var scheduler: ((Bool, @escaping @Sendable () -> Void) -> Void)?
}

private final class ContinuationClaimBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private final class SendableContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    /// onCancel 先于 store() 执行时置位;后续 store() 立即以 CancellationError 恢复,
    /// 避免续体永不恢复导致任务挂起。
    private var cancelledBeforeStore = false

    func store(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if cancelledBeforeStore {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let pending = continuation
        if pending == nil {
            cancelledBeforeStore = true
        } else {
            continuation = nil
        }
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}
