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
    /// 单流输出上限(默认 64 MB);`run` 的 `outputLimitBytes` 默认取本值,该参数仅测试注入更小值覆盖超限链路。
    static let defaultOutputLimitBytes = 64 * 1024 * 1024

    /// 每次 git 调用统一前置的全局配置覆盖(必须排在子命令之前)。
    /// 威胁模型:**仓库自带的 `.git/config` 可把配置键指向任意可执行程序**,本 app 的周期性只读命令会去执行它
    /// ——等于"打开工作区看一眼"就运行了仓库带来的代码。
    /// - `core.fsmonitor=false`:`git status`/`git diff` 会执行它指向的脚本(还会 fork 一个 `--detach` daemon,`terminate()` 杀不掉)。
    /// - `core.askPass=`:仓库把 askpass 配成 `!<命令>` 时 git 在认证时直接 exec;`GIT_TERMINAL_PROMPT=0` 只关终端打字提示、
    ///   不关 askpass;实测空值被 git 当作"未配置"不会 exec。环境里的 `GIT_ASKPASS`/`SSH_ASKPASS` 属用户信任域,保持透传。
    /// - **刻意不放 `diff.external=`**:覆盖成空值会让 git 认为外部 diff 已启用并去 exec 空命令,`git diff` 直接 fatal——
    ///   外部 diff 与 textconv 靠命令行开关 `--no-ext-diff --no-textconv` 封堵(见 GitService 补丁类命令)。
    /// - 凭据 helper 链单独由 `credentialGuardArguments(userHelpers:)` 处理,不能与这些写死空值的项混为一谈。
    /// - `core.sshCommand` 不在此列:`childEnvironment` 恒写 `GIT_SSH_COMMAND`,env 优先级高于仓库配置,已封死。
    /// - 钩子(`.git/hooks`、`core.hooksPath`)**不**禁:静默屏蔽会制造"app 里提交没跑钩子"的隐性差异。
    /// 代价只有性能与少量能力:fsmonitor 关后全量扫描结果仍正确;仓库自带 helper 失效后认证回落用户全局配置。
    static let fixedGlobalConfigurationArguments: [String] = [
        "-c", "core.fsmonitor=false",
        "-c", "core.askPass=",
    ]

    /// 凭据 helper 链覆盖:先重置再回填用户自己全局/系统声明的 helper。
    /// 仓库 `.git/config` 的 `credential.helper = !<命令>` 在认证时会被 exec,`GIT_TERMINAL_PROMPT=0` 关不掉,必须在 `-c` 层面重置;
    /// 但一刀切空值会连用户的 `osxkeychain` 一起抹掉、私有仓库当场认证失败——攻击面只在仓库那一条,故把用户声明的原样追加回来。
    static func credentialGuardArguments(userHelpers: [String]) -> [String] {
        var arguments = ["-c", "credential.helper="]
        for helper in userHelpers {
            let trimmed = helper.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            arguments.append(contentsOf: ["-c", "credential.helper=\(trimmed)"])
        }
        return arguments
    }

    static func globalConfigurationArguments(userHelpers: [String]) -> [String] {
        fixedGlobalConfigurationArguments + credentialGuardArguments(userHelpers: userHelpers)
    }

    /// 用户全局/系统 credential helper。只缓存读取成功的结果;失败不缓存、下次调用重试——一次瞬时故障否则会把私有仓库认证钉死到重启。
    /// 失败那轮按空返回 = fail-closed:宁可不回填,也不能把仓库带来的 helper 留在链上悄悄执行。
    private static let userHelpersCache = UserCredentialHelperCache()

    /// 用 actor 而非 `NSLock`:Swift 6 SDK 起 `lock()/unlock()` 在 async 上下文不可用(`NS_SWIFT_UNAVAILABLE_FROM_ASYNC`),而发现要起子进程、须跨调用复用结果。
    /// internal 供单测注入 loader,区分 nil(没读成功)与 [](确实没配 helper)两种空值。
    actor UserCredentialHelperCache {
        private var cached: [String]?

        func helpers() async -> [String] {
            await helpers(loader: {
                // 阻塞式 Process 读取必须离开 actor 的 executor(调用方可能是主线程)。
                await Task.detached(priority: .utility) {
                    GitProcessRunner.readUserCredentialHelpers()
                }.value
            })
        }

        func helpers(loader: @Sendable () async -> [String]?) async -> [String] {
            if let cached { return cached }
            guard let loaded = await loader() else {
                // nil=没读成功:本轮 fail-closed 返回空但不入缓存,下次重试(见 userHelpersCache)。
                return []
            }
            cached = loaded
            return loaded
        }
    }

    static func resolvedGlobalConfigurationArguments() async -> [String] {
        Self.globalConfigurationArguments(userHelpers: await Self.userHelpersCache.helpers())
    }

    /// 凭据 helper 发现的等待上限:结果虽只缓存一次,但坐在**每次** git 调用的关键路径上,而 `waitUntilExit` 本身无时限——一条阻塞的 `git config` 足以冻住全 app 的 git 能力。
    private nonisolated static let credentialDiscoveryTimeout: TimeInterval = 5

    /// 读用户自己的 credential.helper(system + global 合并值)。直接用 Process 不走 `run()`:run() 会把本函数产出前置进 argv(自指),且发现必须与目标仓库无关。
    /// **不带 `--global`/`--system`,在非仓库目录读合并值**:分作用域读会漏掉 XDG(`~/.config/git/config`)与 `[include]` 文件——漏读等价于抹掉用户的 osxkeychain;
    /// cwd 取临时目录(非任何工作区),环境过 `childEnvironment`(GIT_DIR/GIT_CONFIG_* 已剔除),不会被外部指向别的仓库或配置文件。
    /// 返回值区分两种空:`[]` = 确实未配置(可信,可缓存);`nil` = 没读成功(启动失败/超时/被信号终止/解码失败,不得缓存)。
    private nonisolated static func readUserCredentialHelpers() -> [String]? {
        guard let gitURL else { return nil }
        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["config", "--get-all", "credential.helper"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.environment = Self.childEnvironment(inherited: ProcessInfo.processInfo.environment)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        var launched = false
        var exception: NSException?
        ObjCExceptionCatchTryRun({
            do {
                try process.run()
                launched = true
            } catch {
                launched = false
            }
        }, &exception)
        guard launched, exception == nil else {
            // 读不到即 fail-closed(见 userHelpersCache 注释)。
            return nil
        }

        let processBox = SendableProcessBox(process)
        let timeoutWork = DispatchWorkItem {
            guard processBox.process.isRunning else { return }
            Self.objCBridgedTerminate(processBox.process)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.credentialDiscoveryTimeout,
            execute: timeoutWork
        )
        process.waitUntilExit()
        timeoutWork.cancel()

        // 被信号终止(含上面那次超时兜底)不等于"没有配置"。
        guard process.terminationReason == .exit else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        // `--get-all` 无匹配时以退出码 1 结束:这是"确实一个 helper 都没配"的可信空值。
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        guard process.terminationStatus == 0 else { return [] }
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        return Self.decodedConfigLines(data)
    }

    /// 按行拆分并去空行;internal 供单测覆盖多行/尾换行形态。
    static func decodedConfigLines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static let gitURL: URL? = {
        let candidates = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

    /// 组装 git 子进程环境(纯函数,便于单测——不碰进程级 setenv)。先剥继承的 git 覆盖变量,再合并注入项,最后写死安全/分类固定项。
    static func childEnvironment(
        inherited: [String: String],
        additional: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited
        // 剥掉继承环境里的 git 覆盖变量:app 若从 git shell 函数/wrapper 启动,GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE 会进入每个子进程并**压过**
        // `-C <目录>` 定位——所有操作指向启动它的那个仓库,且因命令"成功"而错误不可归因;GIT_CONFIG* 同理会绕过下方固定项。
        // GIT_CONFIG_PARAMETERS 是 `git -c` 的进程间续传形式,留着可从环境重塞 `core.fsmonitor=<脚本>` 绕过前置覆盖(实测生效);
        // GIT_EXTERNAL_DIFF/GIT_PATCH_COMMAND/GIT_PROXY_COMMAND 同属"环境变量指向可执行程序",一并剥掉。
        // 刻意**不**剥 GIT_ASKPASS/SSH_ASKPASS:来自调用方环境(编辑器/用户脚本),属用户信任域、仓库无法写入,剥掉不缩小攻击面,
        // 却会让从 IDE 集成终端启动 app 的用户失去私有仓库认证;要封的是仓库自带那条(`-c core.askPass=`)。
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
            "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT",
            "GIT_CONFIG_PARAMETERS", "GIT_EXTERNAL_DIFF", "GIT_PATCH_COMMAND",
            "GIT_PROXY_COMMAND",
        ] {
            environment.removeValue(forKey: key)
        }
        environment.merge(additional) { _, injected in injected }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // 用户已有 GIT_SSH_COMMAND 时**追加** -o BatchMode=yes 而非整体覆盖:覆盖会静默丢弃其自定义密钥/端口/代理,clone/pull 认证失败且无从排查。
        if let existingSSHCommand = environment["GIT_SSH_COMMAND"],
           existingSSHCommand.trimmingCharacters(in: .whitespaces).isEmpty == false {
            environment["GIT_SSH_COMMAND"] = existingSSHCommand + " -o BatchMode=yes"
        } else {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        // 固定输出语言为英文:全项目错误分类都依赖英文文案子串,用户 shell 里一个 LANG=zh_CN 就能让整套分类静默失效。
        environment["LC_ALL"] = "C"
        // 安全兜底:只放行白名单传输协议(git 默认允许 ext:: 等可执行任意命令的形式,用户配置的远端 URL 会原样进 argv);
        // Service 层入口另有 GitURLParser.validateRemoteURL,这里双保险。
        environment["GIT_ALLOW_PROTOCOL"] = "https:http:ssh:git:file"
        return environment
    }

    func run(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60,
        /// 注入项在基础环境之后、固定项之前合并:LC_ALL/GIT_ALLOW_PROTOCOL 等安全与分类固定项不被覆盖。
        additionalEnvironment: [String: String] = [:],
        /// 单流输出上限(**仅测试用**:压小以覆盖超限链路);生产路径恒为默认值。
        outputLimitBytes: Int = GitProcessRunner.defaultOutputLimitBytes
    ) async throws -> GitProcessResult {
        guard let gitURL = Self.gitURL else {
            throw NSError(
                domain: "GitProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 git 可执行文件"]
            )
        }
        // 已取消任务快速失败:不白起进程,也规避 onCancel 先于 body 执行的时序问题。
        try Task.checkCancellation()

        // 进程入口最后防线:含 NUL 的参数在 Swift 桥接 C 字符串构造 argv 时会 fatalError 崩掉整个 App(手工编辑的 JSON 配置可注入),兜底拒绝执行。
        if arguments.contains(where: { $0.utf8.contains(0) }) {
            throw NSError(
                domain: "GitProcessRunner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "命令参数包含非法控制字符，已拒绝执行"]
            )
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = await Self.resolvedGlobalConfigurationArguments() + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        process.environment = Self.childEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            additional: additionalEnvironment
        )

        let stdoutPipe = captureStdout ? Pipe() : nil
        let stderrPipe = captureStderr ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        process.standardError = stderrPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let processBox = SendableProcessBox(process)
        let continuationClaim = ContinuationClaimBox()
        let commandDescription = Self.safeCommandDescription(arguments: arguments)
        // 排水兜底调度器定义在 continuation 闭包体内,onCancel 需在取消路径复用它(见其注释),经 box 中转;
        // onCancel 先于 body 执行时为 nil——此时进程未启动,body 的失败清理路径会摘 handler。
        let drainSchedulerBox = DrainSchedulerBox()
        let timeoutBox = TimeoutWorkItemBox()

        let continuationBox = SendableContinuationBox<GitProcessResult>()
        // 进程退出后管道读端可能被子进程(如 ssh)继续持有,EOF 迟迟不来;超时定时器在正常退出路径已被取消,排水本身也需兜底时限。
        let drainFallbackInterval: TimeInterval = 30

        // 续体恢复后必须摘掉调度器,否则 DataBox → onOverflow → DrainSchedulerBox → scheduler → DataBox 构成每次调用必现的强引用环,
        // 环上的 Process 与两条 Pipe(4 个 fd)永不释放,fd 耗尽后 `process.run()` 全线失败。摘除后 scheduler 只可能被 onCancel/超限回调读到,两路径已自行恢复续体或自带清理。
        defer { drainSchedulerBox.scheduler = nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.store(continuation)

                // 输出超限:与超时路径同构——恰好一次认领续体、终止进程(SIGTERM + 5s SIGKILL 升级)、借排水兜底摘读回调并平衡 group,再以超限错误失败本次运行。
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

                let stdoutBox = SendableDataBox(maxBytes: outputLimitBytes, onOverflow: handleOutputOverflow)
                let stderrBox = SendableDataBox(maxBytes: outputLimitBytes, onOverflow: handleOutputOverflow)
                let readGroup = DispatchGroup()
                let stdoutRead = ReadFinalizer(group: readGroup)
                let stderrRead = ReadFinalizer(group: readGroup)

                // 用 readabilityHandler 增量读取,不用阻塞式 readDataToEndOfFile:阻塞读期间从其他线程 closeFile 属未定义行为(FileHandle 可能在后台队列抛 ObjC 异常崩进程);
                // handler 在 EOF 时自摘除,fd 由 Pipe 释放引用后在 deinit 关闭,任何路径都不需要强制 close。
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

                /// 排水兜底:进程退出后管道读端可能被残留子进程(如 ssh)持有,EOF 迟迟不来;兜底超时后摘除读回调并以已有数据恢复续体,续体 resume 幂等、双恢复安全。
                /// isTimeoutPath=true:即使管道排干失败也必须恢复为超时错误,而不是"被 SIGTERM 的退出码 + 半截输出"的伪成功。
                nonisolated(unsafe) let scheduleDrainFallback: (Bool, @escaping @Sendable () -> Void) -> Void = { isTimeoutPath, resume in
                    let drainWorkBox = DrainWorkBox()
                    nonisolated(unsafe) let cleanup: () -> Void = { [processBox, continuationBox, stdoutRead, stderrRead] in
                        // 只摘回调不 closeFile:与回调执行竞态的 close 属未定义行为;Pipe 在 deinit 关闭 fd。
                        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                        stderrPipe?.fileHandleForReading.readabilityHandler = nil
                        // EOF 永不到来,补偿性 leave(与 EOF 路径互斥、恰好一次)让 notify 落地。
                        if stdoutPipe != nil { stdoutRead.finalize() }
                        if stderrPipe != nil { stderrRead.finalize() }
                        if isTimeoutPath {
                            if Self.objCBridgedIsRunning(processBox.process) {
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
                        // 截断即失败:与 terminationHandler 路径同因(见那里的注释)。
                        if stdoutBox.isTruncated || stderrBox.isTruncated {
                            continuationBox.resume(
                                throwing: GitProcessExecutionError.outputLimitExceeded(
                                    command: commandDescription
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
                    drainWorkBox.store(cleanup)
                    nonisolated(unsafe) let drainFallbackWork = DispatchWorkItem { [drainWorkBox] in
                        drainWorkBox.takeForFire()?()
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + drainFallbackInterval,
                        execute: drainFallbackWork
                    )
                    readGroup.notify(queue: .global()) {
                        // 排干即摘执行体:cancel() 只是标记,队列会把 item 真身持到兜底时限,不摘则 Process/两条 Pipe 陪跑 30s。
                        drainWorkBox.clear()
                        drainFallbackWork.cancel()
                        resume()
                    }
                }
                drainSchedulerBox.scheduler = scheduleDrainFallback

                nonisolated(unsafe) let timeoutWork = DispatchWorkItem { [processBox, continuationClaim] in
                    // isRunning 复查必须先于认领:进程已退出时让 terminationHandler 正常持有续体恢复权,顺序不可对调。
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
                timeoutBox.store(timeoutWork)

                process.terminationHandler = { completedProcess in
                    // 摘 handler 必须先于认领判定:handler 闭包捕获 stdoutBox/scheduleDrainFallback、后者经 processBox 回指 Process 构成环;
                    // 若放在 claim 失败提前 return 之后,环永久留在图上,Process + 两条 Pipe 的 fd 与输出缓冲长期滞留。
                    completedProcess.terminationHandler = nil
                    timeoutBox.release()
                    guard continuationClaim.claim() else { return }
                    scheduleDrainFallback(false) {
                        // 截断即失败:溢出回调与进程退出抢同一个 claim,若本路径先认领而截断恰在退出后发生(最后一块读缓冲 + 64KB 内核 pipe 未交付),
                        // 照旧 resume 成功会让调用方拿到"退出码 0 + 被砍断的输出"并当作合法 git 输出去解析。
                        if stdoutBox.isTruncated || stderrBox.isTruncated {
                            continuationBox.resume(
                                throwing: GitProcessExecutionError.outputLimitExceeded(
                                    command: commandDescription
                                )
                            )
                            return
                        }
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
                    // 启动前再查一次取消:onCancel 可能在 body 执行到此处之前已触发(续体已恢复),但 body 是同步闭包仍会把进程跑起来——用户点了取消,git clone 仍在后台下载写目录。
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
                    // 启动失败判定用正向信号认领式,不用 isRunning:Foundation 回收线程与 terminationHandler 投递并发,
                    // 毫秒级瞬时命令在 run() 返回前后 isRunning 可能已为 false,以它判定会产出"exec 实际成功"的假错误。
                    // - run() 正常返回即 spawn 成功,退出状态由先装好的 terminationHandler 接管恢复;
                    // - 抛了 ObjC 但续体认领已被取走或已有有效 pid:进程确已启动、会正常退出恢复续体,不能报启动失败;
                    // - 仅"异常且无任何已 spawn 迹象"才是真启动失败,走下方 catch 的既有清理。
                    if !launched, continuationClaim.isClaimed == false,
                       Self.objCBridgedProcessIdentifier(process) == nil {
                        // 异常消息同时带 name 与 reason:只有 reason 无法区分异常类别。
                        let message = launchException.map { "\($0.name): \($0.reason ?? "")" }
                            ?? "进程启动失败"
                        throw NSError(
                            domain: "GitProcessRunner",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    // run() 与前置取消检查之间仍有窗口:onCancel 恰在此间触发,进程被启动却无人 terminate(续体已被取消路径恢复)。
                    // 启动成功后再判一次,发现取消立即终止,只浪费一次 fork 而非整条命令。
                    if Task.isCancelled {
                        process.terminationHandler = nil
                        Self.objCBridgedTerminate(process)
                        // 与 onCancel 的 SIGKILL 升级对称:onCancel 判定发生在启动前,覆盖不到这个窗口。
                        Self.scheduleSIGKILLEscalation(processBox: processBox)
                        throw CancellationError()
                    }
                } catch {
                    process.terminationHandler = nil
                    timeoutBox.release()
                    // 摘回调与平衡 group 必须无条件执行:若放在 claim 成功分支内,onCancel 抢先取走 claim 时直接 return,
                    // readabilityHandler 永不移除——进程从未启动、EOF 永不到来,Pipe/fd 与捕获闭包永久泄漏。
                    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                    stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    if stdoutPipe != nil { stdoutRead.finalize() }
                    if stderrPipe != nil { stderrRead.finalize() }
                    guard continuationClaim.claim() else { return }
                    continuationBox.resume(throwing: error)
                    return
                }

                // 到期闭包只捕获小盒子(见 TimeoutWorkItemBox):release() 后这里空转一次。
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    timeoutBox.takeForFire()?.perform()
                }
            }
        } onCancel: {
            if Self.objCBridgedIsRunning(processBox.process) {
                Self.objCBridgedTerminate(processBox.process)
                // SIGKILL 升级:SIGTERM 可能被挂起的 git(等锁、D 状态 IO)吞掉,不升级就等于被取消的操作长期锁住工作区(index.lock)。
                Self.scheduleSIGKILLEscalation(processBox: processBox)
            }
            // 不 closeFile:读端由 readabilityHandler 在 EOF 时自摘除,强制 close 与回调执行竞态属未定义行为;续体立即以 CancellationError 恢复,不依赖排水。
            if continuationClaim.claim() {
                continuationBox.cancel()
                // 被杀的 git 可能有孙进程(如 ssh)继续持有管道写端,EOF 永不到来:借排水兜底完成"摘 handler + 平衡 group"——
                // 续体已取消,兜底路径的 resume 是幂等空操作,只利用其清理副作用;调度器尚未存入时进程未启动,body 的失败清理路径会摘 handler。
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

    /// 单个 argv 片段脱敏:内联凭据(URL userinfo)与 `?token=` 类查询参数一并打码。
    /// internal 供单测。与 `GitServiceError.redactCredentials`(作用于任意文本)是两份独立实现,口径必须同步演进——任一处漏打码都会把令牌写进日志/UI。
    static func redactedArgument(_ argument: String) -> String {
        guard var components = URLComponents(string: argument) else {
            return argument
        }

        var redactedQuery = false
        if var queryItems = components.queryItems, queryItems.isEmpty == false {
            // 托管平台常以 ?private_token=... 传令牌,诊断文案同样不能泄漏。
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

    /// Process 在已退出/从未启动状态下 terminate/isRunning 可能抛 ObjC 异常(isRunning 检查与 terminate 横跨线程,竞态窗口无法根除),未捕获的 NSException 直接崩 App。
    /// 对死进程的终止本就是幂等空操作,所有终止/探活调用一律经 ObjC 桥接吞异常。
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

    /// 桥接读取 pid:从未启动的进程读 processIdentifier 可能抛 ObjC 异常;返回 nil = 无有效 pid(从未 spawn),供启动确认判定用。
    private static func objCBridgedProcessIdentifier(_ process: Process) -> pid_t? {
        var pid: pid_t = 0
        var exception: NSException?
        let succeeded = ObjCExceptionCatchTryRun({ pid = process.processIdentifier }, &exception)
        guard succeeded, exception == nil, pid != 0 else { return nil }
        return pid
    }

    /// SIGTERM 可能被挂起的 git(等锁、D 状态 IO)吞掉:5s 后仍存活则升级 SIGKILL,避免残留进程长期持有工作区(如 index.lock);isRunning 复查经 ObjC 桥接防崩。
    /// internal + `escalationDelay` 仅供单测直接驱动这条分支并缩短等待;生产调用方只有 `run` 内部三处。
    static func scheduleSIGKILLEscalation(
        processBox: SendableProcessBox,
        escalationDelay: TimeInterval = 5
    ) {
        DispatchQueue.global().asyncAfter(deadline: .now() + escalationDelay) { [processBox] in
            if Self.objCBridgedIsRunning(processBox.process) {
                kill(processBox.process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Process 的 Sendable 转发盒;internal 供单测构造以驱动 `scheduleSIGKILLEscalation`,生产构造点只有 `run`。
final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

/// 增量读取缓冲:单流硬上限,超限时停止追加(截断)并恰好一次触发溢出回调,由调用方终止进程并失败本次运行——否则超大 `git diff` 会在超时兜底生效前耗尽内存。
/// internal 供单测直接覆盖"截断 + 恰好一次溢出回调"契约;生产构造点只有 `run`。
final class SendableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var _data = Data()
    private var _truncated = false
    private var _overflowNotified = false
    private let onOverflow: @Sendable () -> Void

    init(maxBytes: Int, onOverflow: @escaping @Sendable () -> Void) {
        self.maxBytes = maxBytes
        self.onOverflow = onOverflow
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }

    /// 该流是否触顶被截断。恢复续体前必须复查:溢出回调与进程退出竞态时,截断的数据不得按成功返回(见 `run` 两处截断守卫)。
    var isTruncated: Bool {
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
        let remaining = maxBytes - _data.count
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

/// 排水兜底调度器的转发盒:onCancel 在 continuation 闭包体外,经此类中转(body 线程写、onCancel 线程读)。
/// 两侧线程不同,必须锁保护——`@unchecked Sendable` 只是消音,裸 Optional 属性的并发读写是 data race。
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

/// 兜底排水执行体的转发盒:队列会把被 `cancel()` 的 item 真身持到自身 deadline,若 item 直接捕获清理闭包,Process 与两条 Pipe(4 个 fd)要陪跑到 deadline。
/// 正常排干时 clear() 摘走执行体、队列里只剩空盒子;EOF 不来时执行体仍在盒内,兜底清理按原语义执行。
private final class DrainWorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    func store(_ cleanup: @escaping () -> Void) {
        lock.lock()
        self.cleanup = cleanup
        lock.unlock()
    }

    /// 排干完成(两条管道均 EOF、group 已平衡)后摘除执行体,此后到期的 item 空转。
    func clear() {
        lock.lock()
        cleanup = nil
        lock.unlock()
    }

    func takeForFire() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return cleanup
    }
}

/// 超时 work item 的转发盒(与 DrainWorkBox 同一动机):到期闭包只捕获小盒子,`cancel()` 只是标记、真身仍被队列持到超时上限(clone 600s);
/// release() 摘除真身,避免 Process/Pipe/续体 box 链白滞留十分钟。
private final class TimeoutWorkItemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?

    func store(_ item: DispatchWorkItem) {
        lock.lock()
        workItem = item
        lock.unlock()
    }

    /// 进程退出/失败路径调用:摘除并取消真身,到期闭包届时空转。
    func release() {
        lock.lock()
        let item = workItem
        workItem = nil
        lock.unlock()
        item?.cancel()
    }

    func takeForFire() -> DispatchWorkItem? {
        lock.lock()
        defer { lock.unlock() }
        return workItem
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

    /// 只窥视是否已被认领、不消费:供启动确认判定 terminationHandler 是否已接管退出状态。
    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }
}

private final class SendableContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    /// onCancel 先于 store() 执行时置位;后续 store() 立即以 CancellationError 恢复,避免续体永不恢复导致任务挂起。
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
