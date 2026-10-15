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
    /// 单流输出上限(默认 64 MB)。`run` 的 `outputLimitBytes` 默认取本值;
    /// 该参数**仅测试**用于把上限压到极小以覆盖"截断 → 恰好一次 onOverflow →
    /// 杀进程 → 抛超限错误"整条链路,生产路径恒为默认值、行为零变化。
    static let defaultOutputLimitBytes = 64 * 1024 * 1024

    /// 每次 git 调用统一前置的全局配置覆盖(必须排在子命令之前)。
    ///
    /// 每一项都属于同一威胁模型:**仓库自带的 `.git/config` 可以把某个配置键指到任意
    /// 可执行程序**,而本 app 的周期性只读命令会去执行它——等于"打开工作区看一眼"就
    /// 运行了仓库带来的代码。这些配置随目录一起被拷进工作区并被自动纳管。
    ///
    /// - `core.fsmonitor=false`:`git status`/`git diff` 会执行它指向的脚本
    ///   (实测 Apple Git 157 还会 fork 一个 `--detach` 的 daemon,`terminate()`
    ///   只杀直接子进程、杀不掉它)。
    /// - `core.askPass=`:仓库自带的 `.git/config` 把 askpass 指到 `!<命令>` 时,
    ///   git 在需要认证时会直接 exec 它(实测报 `cannot exec '!sh -c ...'`,即确实走到执行)。
    ///   `GIT_TERMINAL_PROMPT=0` 只关终端打字提示,不关 askpass。
    ///   实测空值被 git 当作"未配置",不会去 exec 空命令(与 `diff.external` 不同,见下)。
    ///   环境里的 `GIT_ASKPASS`/`SSH_ASKPASS` 属用户信任域、保持原样透传,
    ///   这里只压配置文件侧的取值。
    ///
    /// **刻意不放 `diff.external=`**:实测把该键覆盖成空值会让 git 认为外部 diff 已启用
    /// 并去 exec 空命令名,`git diff` 直接 `fatal: external diff died`——为了堵一条路径
    /// 把整个 diff 视图打死。外部 diff 与 textconv 一律靠命令行开关封堵
    /// (`--no-ext-diff --no-textconv`,见 GitService 的补丁类命令):
    /// 实测仓库自带 `.gitattributes` + `diff.<driver>.textconv` 在
    /// `git diff --numstat -p` 下**确实会被执行**,加上这两个开关后被完全拦住。
    ///
    /// 凭据 helper 链单独由 `credentialGuardArguments(userHelpers:)` 处理:它需要
    /// 保留用户自己的全局 helper,不能与上面这些"直接写死空值"的项混为一谈。
    ///
    /// `core.sshCommand` 不在此列:`childEnvironment` 恒写 `GIT_SSH_COMMAND`,
    /// env 优先级高于仓库配置,已实际封死。
    ///
    /// 代价只有性能与少量能力:禁用 fsmonitor 后 git 退化为全量扫描,结果仍正确;
    /// 仓库自带的 askpass/凭据 helper 失效,认证回落到用户全局配置。
    /// 钩子(`.git/hooks`、`core.hooksPath`)这里**不**禁:commit/stash 触发钩子与用户
    /// 在命令行里做同样操作是一致的,静默屏蔽反而制造"app 里提交没跑钩子"的隐性差异。
    static let fixedGlobalConfigurationArguments: [String] = [
        "-c", "core.fsmonitor=false",
        "-c", "core.askPass=",
    ]

    /// 凭据 helper 链覆盖:先重置,再回填用户自己在全局/系统配置里声明的 helper。
    ///
    /// 仓库 `.git/config` 里的 `credential.helper = !<命令>` 在需要认证时会被执行,
    /// 而 `GIT_TERMINAL_PROMPT=0` 只关终端提示、不关 helper 调用,所以这条必须在
    /// `-c` 层面重置。**但不能一刀切**:空值会清掉整条链,连用户全局的
    /// `osxkeychain` 一起抹掉,私有仓库当场拉不下来(认证失败)。攻击面只在
    /// "仓库自带的那一条",因此把用户全局/系统声明的 helper 原样追加回来。
    ///
    /// 纯函数:发现结果由外部传入,便于单测钉死拼接形态。
    static func credentialGuardArguments(userHelpers: [String]) -> [String] {
        var arguments = ["-c", "credential.helper="]
        for helper in userHelpers {
            let trimmed = helper.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            arguments.append(contentsOf: ["-c", "credential.helper=\(trimmed)"])
        }
        return arguments
    }

    /// 组装一次调用的前置参数(固定安全项 + 凭据链覆盖)。
    static func globalConfigurationArguments(userHelpers: [String]) -> [String] {
        fixedGlobalConfigurationArguments + credentialGuardArguments(userHelpers: userHelpers)
    }

    /// 用户全局/系统 credential helper,首次 git 调用时读一次并缓存。
    /// 读取失败按空处理 = fail-closed:宁可不回填(认证明确失败可归因),
    /// 也不能把仓库带来的 helper 留在链上悄悄执行。
    private static let userHelpersCache = UserCredentialHelperCache()

    /// 凭据 helper 发现结果的缓存载体。
    ///
    /// 用 actor 而不是 `NSLock`:Swift 6 SDK 起 `lock()/unlock()` 在 async 上下文
    /// 直接不可用(`NS_SWIFT_UNAVAILABLE_FROM_ASYNC`),而发现本身要起子进程、
    /// 必须跨调用复用同一结果。
    private actor UserCredentialHelperCache {
        private var cached: [String]?

        func helpers() async -> [String] {
            if let cached { return cached }
            // 阻塞式 Process 读取必须离开 actor 的 executor(调用方可能是主线程)。
            let loaded = await Task.detached(priority: .utility) {
                GitProcessRunner.readUserCredentialHelpers()
            }.value
            cached = loaded
            return loaded
        }
    }

    static func resolvedGlobalConfigurationArguments() async -> [String] {
        Self.globalConfigurationArguments(userHelpers: await Self.userHelpersCache.helpers())
    }

    /// 读用户自己的 credential.helper(system + global 合并值)。
    ///
    /// 直接用 Process,不走 `run()`:一是 `run()` 会把本函数的产出前置进 argv(自指),
    /// 二是发现调用必须与目标仓库无关。
    ///
    /// **不带 `--global`/`--system` 作用域参数,而是在非仓库目录读合并值**:
    /// 分作用域读会漏掉 XDG(`~/.config/git/config`)与 `[include]` 引进来的文件,
    /// 而这两种恰恰是 macOS 上常见的 helper 声明位置;漏读等价于把用户的
    /// osxkeychain 抹掉,私有仓库立刻拉不下来。cwd 取 `NSTemporaryDirectory()`
    /// (非任何工作区仓库),合并结果即 system+global,不含仓库自带的 local 值。
    /// 环境仍过 `childEnvironment`:继承来的 `GIT_DIR`/`GIT_CONFIG_*` 已被剔除,
    /// 不会被外部指向到别的仓库或配置文件。
    private nonisolated static func readUserCredentialHelpers() -> [String] {
        guard let gitURL else { return [] }
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
            // 读不到就 fail-closed:仍下发重置(见 credentialGuardArguments),
            // 宁可不回填,也不能把仓库带来的 helper 留在链上悄悄执行。
            return []
        }
        process.waitUntilExit()
        // 退出码非 0 = 没有任何 helper 配置,按空处理。
        guard process.terminationStatus == 0 else { return [] }
        return Self.decodedConfigLines(outputPipe.fileHandleForReading.readDataToEndOfFile())
    }

    /// 按行拆分 git config 输出并去掉空行(纯函数,便于单测覆盖多行/尾换行形态)。
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

    /// 组装 git 子进程的环境变量(纯函数,便于单测——不碰进程级 setenv)。
    ///
    /// 先剥掉继承环境里的 git 覆盖变量,再合并调用方注入项,最后写死安全/分类固定项。
    static func childEnvironment(
        inherited: [String: String],
        additional: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited
        // 剥掉调用方环境里的 git 覆盖变量:app 若从 git shell 函数(别名/wrapper)里
        // 启动,GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE 会随继承进入每个子进程并**压过**
        // `-C <目录>` 定位——所有 git 操作都被指向启动它的那个仓库,且因为命令"成功
        // 执行"了,错误完全不可归因。GIT_CONFIG*/GIT_SSH_COMMAND 同理论外部 system
        // 配置可绕过下方固定项(GIT_SSH_COMMAND 在下面单独追加处理,不在此剔除)。
        //
        // GIT_CONFIG_PARAMETERS 是 `git -c` 的进程间续传形式,键值全由它说了算,留着
        // 就能从环境里把 `core.fsmonitor=<脚本>` 重新塞回来、绕过
        // `globalConfigurationArguments` 的前置覆盖(实测生效)。GIT_EXTERNAL_DIFF 与
        // GIT_PROXY_COMMAND 同属"环境变量指向可执行程序",一并剥掉
        // (GIT_PATCH_COMMAND 是 GIT_EXTERNAL_DIFF 的配套程序名,跟着一起剥,单留它
        // 不起作用)。
        //
        // 刻意**不**剥 GIT_ASKPASS/SSH_ASKPASS:这两个来自调用方环境(编辑器/用户脚本),
        // 属用户信任域,仓库无法写入,剥掉不会缩小任何攻击面,却会让从 VS Code 集成
        // 终端启动 app 的用户失去私有仓库认证能力。要封的是**仓库自带**的那一条,
        // 走 `-c core.askPass=`(见 globalConfigurationArguments)。
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
        // 固定非交互 ssh:用户已有 GIT_SSH_COMMAND 时**追加** -o BatchMode=yes 而非
        // 整体覆盖——用户可能借它指定自定义密钥/端口/代理,整体覆盖会把配置静默丢弃,
        // clone/pull 认证失败且无从排查。BatchMode 仍保证不弹交互提示。
        if let existingSSHCommand = environment["GIT_SSH_COMMAND"],
           existingSSHCommand.trimmingCharacters(in: .whitespaces).isEmpty == false {
            environment["GIT_SSH_COMMAND"] = existingSSHCommand + " -o BatchMode=yes"
        } else {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        // 固定 git 输出语言为英文:全项目的错误分类(pull 策略回退、分支缺失判定、
        // stash 恢复决策、localizeMessage 之外的子串匹配)都依赖英文文案子串。
        // 不设防时用户 shell 里一个 LANG=zh_CN 就能让整套分类逻辑静默失效。
        environment["LC_ALL"] = "C"
        // 安全兜底:只放行白名单传输协议。git 对用户直接发起的命令默认允许 ext::
        // 等可执行任意命令的传输形式,用户配置的远端 URL 会原样进入 argv;
        // Service 层入口另有 URL 校验(GitURLParser.validateRemoteURL),这里双保险。
        environment["GIT_ALLOW_PROTOCOL"] = "https:http:ssh:git:file"
        return environment
    }

    func run(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60,
        /// 额外注入子进程的环境变量（**仅测试用**：配置隔离，如 GIT_CONFIG_GLOBAL）。
        /// 默认空 → 生产路径零变化。注入项在基础环境之上、固定项之前合并，
        /// LC_ALL/GIT_ALLOW_PROTOCOL 等安全与分类固定项不被覆盖。
        additionalEnvironment: [String: String] = [:],
        /// 单流输出上限（**仅测试用**：压小以覆盖超限链路）。生产路径恒为默认值。
        outputLimitBytes: Int = GitProcessRunner.defaultOutputLimitBytes
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
        // 排水兑底的调度器在 continuation 闭包体内定义,onCancel 需要在取消路径
        // 复用它(见 onCancel 注释),经 box 中转。onCancel 先于 body 存入时为 nil,
        // 此时进程未启动,body 自己的失败清理路径会摘 handler。
        let drainSchedulerBox = DrainSchedulerBox()
        // 超时 work item 经 box 中转:见 TimeoutWorkItemBox 注释(到期闭包只捕获小盒子)。
        let timeoutBox = TimeoutWorkItemBox()

        let continuationBox = SendableContinuationBox<GitProcessResult>()
        // 进程退出后,管道读端可能被子进程(如 ssh)继续持有,EOF 迟迟不来;
        // 超时定时器在正常退出路径已被取消,因此排水本身也需要兜底时限。
        let drainFallbackInterval: TimeInterval = 30

        // 收尾摘掉排水调度器:它强引用 scheduleDrainFallback 闭包,而该闭包又强引用
        // stdoutBox/stderrBox,两个 box 的 onOverflow 反过来引用本 box——
        // DataBox → onOverflow → DrainSchedulerBox → scheduler → DataBox 是每次调用
        // 必现的强引用环,环上的 Process 与两条 Pipe 永不释放,即每次 git 调用泄漏 4 个 fd。
        // 数小时累积到 fd 上限后 `process.run()` 全线失败,而上游读取用 `try?` 吞掉错误,
        // 表现就是"仓库状态永远加载不出来、点刷新也没反应"。
        // 摘除时机是续体已恢复之后:此后 scheduler 只可能被 onCancel/超限回调读到,
        // 两条路径要么已自行恢复续体,要么兜底排水 item 早已入队并自带清理。
        defer { drainSchedulerBox.scheduler = nil }

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

                let stdoutBox = SendableDataBox(maxBytes: outputLimitBytes, onOverflow: handleOutputOverflow)
                let stderrBox = SendableDataBox(maxBytes: outputLimitBytes, onOverflow: handleOutputOverflow)
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
                    // 执行体与 item 分离:item 只攥着这个小盒子,见 DrainWorkBox 注释。
                    let drainWorkBox = DrainWorkBox()
                    nonisolated(unsafe) let cleanup: () -> Void = { [processBox, continuationBox, stdoutRead, stderrRead] in
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
                    drainWorkBox.store(cleanup)
                    nonisolated(unsafe) let drainFallbackWork = DispatchWorkItem { [drainWorkBox] in
                        // 已摘除执行体(正常排干)时空转。
                        drainWorkBox.takeForFire()?()
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + drainFallbackInterval,
                        execute: drainFallbackWork
                    )
                    readGroup.notify(queue: .global()) {
                        // 排干即摘执行体:`cancel()` 只是标记,队列仍会把 item 真身持到
                        // 兜底时限(生产 30s),item 若直接捕获清理闭包,Process 与两条 Pipe
                        // 的 4 个 fd 就要陪跑到时限结束——每次 git 调用都摊上 30 秒滞留,
                        // 会被 5s/30s 的周期刷新叠成可观的稳态占用。
                        drainWorkBox.clear()
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
                timeoutBox.store(timeoutWork)

                process.terminationHandler = { completedProcess in
                    // 主动摘除:handler 闭包捕获 stdoutBox/scheduleDrainFallback,后者又经
                    // processBox 回指 Process,构成反向引用环。取消/异常路径都会置 nil,
                    // 正常退出路径此前依赖"Foundation 回收后自行释放"这一未验证前提;
                    // 每次 git 调用泄漏 Process + Pipe + 最大 64MB 缓冲会被 5s 周期刷新放大。
                    // 摘除必须先于认领判定:claim 失败(取消/超时已接管退出状态)时的提前
                    // return 会让上面的摘除永远不执行,Process → handler → processBox → Process
                    // 的环就此永久留在图上,两条 Pipe 的 fd 与输出缓冲一起长期滞留。
                    completedProcess.terminationHandler = nil
                    timeoutBox.release()
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
                    // 判定依据(评审项 1):Foundation 回收线程与 terminationHandler
                    // 投递并发——CPU 抢占下,`rev-parse --verify -q HEAD`、
                    // `merge-base --is-ancestor` 这类毫秒级瞬时命令在 run() 返回前后
                    // isRunning 就可能已被置 false,以 isRunning 判启动失败会产出
                    // "exec 实际成功"的假错误。改为正向信号认领式判定:
                    // - run() 正常返回(launched 且无 swiftError)即 spawn 已成功,
                    //   退出状态由先于 run() 装好的 terminationHandler 接管恢复;
                    // - 抛了 ObjC 异常但续体认领已被取走(terminationHandler 已接管
                    //   退出状态)或已有有效 pid(spawn 确实发生):进程会正常退出并
                    //   恢复续体,不能报"启动失败";
                    // - 仅当异常且无任何已 spawn 迹象,才是真启动失败,走下方 catch
                    //   的既有清理(摘 handler、平衡 group、恢复续体)报错。
                    if !launched, continuationClaim.isClaimed == false,
                       Self.objCBridgedProcessIdentifier(process) == nil {
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
                    timeoutBox.release()
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

                // 到期闭包只捕获小盒子:真身若仍被队列引用,Process/Pipe/box 链会
                // 滞留到超时上限(clone 是 600s);release() 后这里只空转一次。
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    timeoutBox.takeForFire()?.perform()
                }
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

    /// 组装成可展示的命令描述(已脱敏)。internal 仅为单测直接覆盖脱敏口径;
    /// 生产调用方只有 `run` 内的错误构造。
    static func safeCommandDescription(arguments: [String]) -> String {
        (["git"] + arguments)
            .map(redactedArgument)
            .joined(separator: " ")
    }

    /// 单个 argv 片段的脱敏:内联凭据(URL userinfo)与 `?token=` 类查询参数一并打码。
    ///
    /// internal 仅为单测覆盖。注意与 `GitServiceError.redactCredentials` 是两份独立
    /// 实现(后者作用于任意文本、靠正则匹配 `scheme://user:pass@host`),两者口径必须
    /// 同步演进——任一处漏打码都会把令牌写进日志/UI。测试对两边都有断言。
    static func redactedArgument(_ argument: String) -> String {
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

    /// 桥接读取 pid:从未启动的进程读 processIdentifier 可能抛 ObjC 异常;
    /// 返回 nil 表示"无有效 pid"(从未 spawn),供启动确认判定使用。
    private static func objCBridgedProcessIdentifier(_ process: Process) -> pid_t? {
        var pid: pid_t = 0
        var exception: NSException?
        let succeeded = ObjCExceptionCatchTryRun({ pid = process.processIdentifier }, &exception)
        guard succeeded, exception == nil, pid != 0 else { return nil }
        return pid
    }

    /// SIGTERM 可能被挂起的 git(等锁、D 状态 IO)吞掉:5s 后仍存活则升级 SIGKILL,
    /// 避免残留 git 进程长期持有工作区(如 index.lock)。isRunning 复查经 ObjC 桥接,
    /// 避免向已回收的 pid 操作时 Foundation 抛异常崩 App。
    ///
    /// `escalationDelay` 默认 5s;**仅测试**注入更小值以缩短等待。
    /// 放宽为 internal 仅为单测能直接驱动这条分支(生产调用方只有 `run` 内部三处)。
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

/// Process 的 Sendable 转发盒。internal(而非 private)是为了让单测能驱动
/// `scheduleSIGKILLEscalation`;生产构造点只有 `run`。
final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

/// 增量读取缓冲:单流硬上限(默认 64 MB,可注入)。超限时停止追加(截断)并恰好一次
/// 触发溢出回调,由调用方终止进程并失败本次运行——否则超大 `git diff` 会在超时兜底
/// 生效前先把内存耗尽。
///
/// internal(而非 private)仅为让单测直接覆盖"截断 + 恰好一次溢出回调"这条契约;
/// 生产构造点只有 `run`。
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

/// 兜底排水执行体的转发盒(与 TimeoutWorkItemBox 同一动机):dispatch 队列会把被 `cancel()`
/// 的 item 真身持有到自身 deadline,若 item 直接捕获清理闭包,闭包里的 Process 与两条 Pipe
/// (4 个 fd)要陪跑到 deadline 才释放。正常排干(两侧 EOF)时 clear() 摘走执行体,队列里
/// 只剩这个空盒子;EOF 迟迟不来时执行体仍在盒内,兜底清理按原语义照常执行。
private final class DrainWorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    func store(_ cleanup: @escaping () -> Void) {
        lock.lock()
        self.cleanup = cleanup
        lock.unlock()
    }

    /// 排干完成后摘除执行体,此后到期的 item 空转。调用点是 readGroup.notify
    /// (两条管道均已 EOF、读回调已自摘、group 已平衡),此刻清理确实无必要。
    func clear() {
        lock.lock()
        cleanup = nil
        lock.unlock()
    }

    /// 到期时取执行体;已 clear 则为 nil。
    func takeForFire() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return cleanup
    }
}

/// 超时 work item 的转发盒:入队的到期闭包只捕获这个小盒子,不直接捕获
/// work item 本身——item 体内捕获 Process/Pipe/续体 box 链,进程正常结束后
/// `cancel()` 只是标记,真身仍被 dispatch 队列引用到超时上限(clone 600s),
/// 整条链会白滞留十分钟。release() 摘除真身,队列里只剩这个空盒子。
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

    /// 到期时取真身;已 release 则为 nil,空转返回。
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

    /// 只窥视是否已被认领、不消费:供启动确认判定"terminationHandler 是否已接管
    /// 本进程的退出状态"(已认领即进程确已启动并退出)。
    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
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
