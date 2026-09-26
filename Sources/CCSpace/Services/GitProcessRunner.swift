import Foundation
import ObjCExceptionCatch

struct GitProcessResult {
    let terminationStatus: Int32
    let stdoutData: Data
    let stderrData: Data
}

enum GitProcessExecutionError: LocalizedError, Equatable {
    case timedOut(command: String, timeout: TimeInterval)
    case outputLimitExceeded(command: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command, let timeout):
            return "操作超时（\(Int(timeout))s），仓库可能过大或网络连接过慢：\(command)"
        case .outputLimitExceeded(let command):
            return "Git 命令输出超过上限（64 MB），已终止：\(command)"
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

        // 最后一道进程入口防线:含 NUL 字节的参数在 Swift 桥接 C 字符串构造 argv 时
        // 会 fatalError 直接崩掉整个 App(手工编辑的 JSON 配置可以注入这种字符串)。
        // 正常路径应在更上游拒绝,这里兜底而不是让进程崩给用户看。
        if arguments.contains(where: { $0.utf8.contains(0) }) {
            throw NSError(
                domain: "GitProcessRunner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "命令参数包含非法控制字符，已拒绝执行"]
            )
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        // 固定 git 输出语言为英文:全项目的错误分类(pull 策略回退、分支缺失判定、
        // stash 恢复决策、localizeMessage 之外的子串匹配)都依赖英文文案子串。
        // 不设防时用户 shell 里一个 LANG=zh_CN 就能让整套分类逻辑静默失效。
        environment["LC_ALL"] = "C"
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

                // 输出超限处理:与超时路径同构——恰好一次认领续体、终止进程
                // (SIGTERM + 5s SIGKILL 升级)、借排水兜底摘读回调并平衡 group,
                // 最后以超限错误失败本次运行。孙进程持有管道导致 EOF 不来时,
                // 清理由兑底定时器兜住;续体已恢复,兜底路径里的 resume 幂等。
                let handleOutputOverflow: @Sendable () -> Void = { [continuationClaim, processBox, drainSchedulerBox, continuationBox, commandDescription] in
                    guard continuationClaim.claim() else { return }
                    Self.objCBridgedTerminate(processBox.process)
                    Self.scheduleSIGKILLEscalation(processBox: processBox)
                    drainSchedulerBox.scheduler?(false, {})
                    continuationBox.resume(
                        throwing: GitProcessExecutionError.outputLimitExceeded(
                            command: commandDescription
                        )
                    )
                }

                let stdoutBox = SendableDataBox(onOverflow: handleOutputOverflow)
                let stderrBox = SendableDataBox(onOverflow: handleOutputOverflow)
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
                            if Self.objCBridgedIsRunning(processBox.process) {
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
                        guard Self.objCBridgedIsRunning(processBox.process) == false else {
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
                    // isRunning 复查必须先于认领:进程已退出时让 terminationHandler
                    // 正常持有续体恢复权,认领顺序不可对调。
                    guard Self.objCBridgedIsRunning(processBox.process) else { return }
                    guard continuationClaim.claim() else { return }
                    Self.objCBridgedTerminate(processBox.process)
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
                        // 异常消息同时携带 name 与 reason:只有 reason 时无法定位
                        // 异常类别(如 NSInvalidArgumentException 与自定义域难以区分)。
                        let message = launchException.map { "\($0.name): \($0.reason ?? "")" }
                            ?? "进程启动失败"
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
                        Self.objCBridgedTerminate(process)
                        // 与 onCancel 的 SIGKILL 升级对称:此刻进程已 isRunning,
                        // 但 onCancel 判定发生在启动前,覆盖不到这个窗口;
                        // SIGTERM 被吞时 5s 后补刀,避免取消的 git 长期锁住工作区。
                        Self.scheduleSIGKILLEscalation(processBox: processBox)
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
            if Self.objCBridgedIsRunning(processBox.process) {
                Self.objCBridgedTerminate(processBox.process)
                // SIGTERM 可能被挂起的 git(等锁、D 状态 IO)吞掉:不升级 SIGKILL
                // 就等于被取消的操作长期锁住工作区(index.lock 一直存在)。
                // 与超时路径的 SIGKILL 升级对称;isRunning 复查避免向已回收的 pid 补刀。
                Self.scheduleSIGKILLEscalation(processBox: processBox)
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
        guard var components = URLComponents(string: argument) else {
            return argument
        }

        var redactedQuery = false
        if var queryItems = components.queryItems, queryItems.isEmpty == false {
            // 凭据类查询参数(private_token / access_token / token 等)一并打码:
            // 托管平台常以 ?private_token=... 传递令牌,诊断文案同样不能泄漏。
            queryItems = queryItems.map { item in
                guard let value = item.value,
                      value.isEmpty == false,
                      item.name.lowercased().contains("token") else {
                    return item
                }
                redactedQuery = true
                return URLQueryItem(name: item.name, value: "redacted")
            }
            if redactedQuery {
                components.queryItems = queryItems
            }
        }

        let hasEmbeddedCredentials = components.user != nil || components.password != nil
        guard hasEmbeddedCredentials || redactedQuery else {
            return argument
        }

        if hasEmbeddedCredentials {
            components.user = "redacted"
            components.password = nil
        }
        return components.string ?? "<redacted-url>"
    }

    /// Process 在已退出/从未启动状态下调用 terminate/isRunning 时,Foundation 可能抛
    /// ObjC 异常(isRunning 检查与 terminate 执行横跨线程,竞态窗口无法根除),
    /// 未捕获的 NSException 会直接崩掉 App。所有终止/探活调用一律经 ObjC 桥接吞异常:
    /// 对死进程的终止本就是幂等空操作,吞掉即可。
    private static func objCBridgedIsRunning(_ process: Process) -> Bool {
        var isRunning = false
        var exception: NSException?
        _ = ObjCExceptionCatchTryRun({ isRunning = process.isRunning }, &exception)
        return isRunning
    }

    private static func objCBridgedTerminate(_ process: Process) {
        var exception: NSException?
        _ = ObjCExceptionCatchTryRun({ process.terminate() }, &exception)
    }

    /// SIGTERM 可能被挂起的 git(等锁、D 状态 IO)吞掉:5s 后仍存活则升级 SIGKILL,
    /// 避免残留 git 进程长期持有工作区(如 index.lock)。isRunning 复查经 ObjC 桥接,
    /// 避免向已回收的 pid 操作时 Foundation 抛异常崩 App。
    private static func scheduleSIGKILLEscalation(processBox: SendableProcessBox) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [processBox] in
            if Self.objCBridgedIsRunning(processBox.process) {
                kill(processBox.process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

/// 增量读取缓冲:单流硬上限 64 MB。超限时停止追加(截断)并恰好一次触发溢出回调,
/// 由调用方终止进程并失败本次运行——否则超大 `git diff` 会在超时兜底生效前
/// 先把内存耗尽。
private final class SendableDataBox: @unchecked Sendable {
    static let maxBytes = 64 * 1024 * 1024

    private let lock = NSLock()
    private var _data = Data()
    private var _truncated = false
    private var _overflowNotified = false
    private let onOverflow: @Sendable () -> Void

    init(onOverflow: @escaping @Sendable () -> Void) {
        self.onOverflow = onOverflow
    }

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }

    /// 超限截断后为真;此后 append 为空操作。
    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _truncated
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard _truncated == false else {
            lock.unlock()
            return
        }
        let remaining = Self.maxBytes - _data.count
        if chunk.count > remaining {
            // 追加到恰好触及上限后截断;溢出回调恰好一次(两个流共用同一处理闭包)。
            if remaining > 0 {
                _data.append(chunk.prefix(remaining))
            }
            _truncated = true
            let shouldNotify = _overflowNotified == false
            _overflowNotified = true
            lock.unlock()
            if shouldNotify {
                onOverflow()
            }
            return
        }
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
/// 存取两侧跑在不同线程(body 线程写、onCancel 线程读),必须锁保护——
/// `@unchecked Sendable` 只是消音,裸 Optional 属性的并发读写在严格并发下是 data race。
private final class DrainSchedulerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduler: ((Bool, @escaping @Sendable () -> Void) -> Void)?

    var scheduler: ((Bool, @escaping @Sendable () -> Void) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _scheduler
        }
        set {
            lock.lock()
            _scheduler = newValue
            lock.unlock()
        }
    }
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
