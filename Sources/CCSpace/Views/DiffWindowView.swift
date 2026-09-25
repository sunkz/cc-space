import SwiftUI

/// Diff 独立窗口的打开参数。
///
/// 作为 `WindowGroup(for:)` 的 value:相等 payload 复用已打开的窗口(聚焦时刷新),
/// 不同 payload 各开一个窗口,可与主窗口并行操作。
struct DiffWindowPayload: Codable, Hashable {
    /// diff 来源:工作区改动、指定 commit 或与某分支对比。
    enum Source: Codable, Hashable {
        case workingDirectory
        case commit(hash: String)
        /// base → head 对比;head 为 nil 表示仓库未检出分支(detached HEAD)。
        case compare(base: String, head: String?)
    }

    let repositoryName: String
    let localPath: String
    let title: String
    let source: Source
}

/// Diff 独立窗口内容:按 payload 加载 diff 并复用 DiffViewerView 展示。
///
/// 以普通窗口(非模态)呈现,不阻塞主窗口;加载与刷新状态由本视图自持,
/// 与触发它的仓库行视图生命周期解耦。
struct DiffWindowView: View {
    let payload: DiffWindowPayload
    let gitService: GitServicing
    let aiCommitService: AICommitMessageServicing

    @State private var entries: [GitDiffEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?
    /// 首次加载是否已完成;用于跳过窗口刚打开时的 becomeKey 通知,避免重复加载。
    @State private var hasLoadedInitialData = false
    /// 待确认丢弃的文件;非 nil 时展示确认弹窗。
    @State private var pendingDiscardEntry: GitDiffEntry?
    @State private var discardErrorMessage: String?
    @State private var isDiscarding = false
    @State private var discardTask: Task<Void, Never>?
    /// 提交信息输入;仅工作区改动来源展示提交栏。
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var commitTask: Task<Void, Never>?
    @State private var commitErrorMessage: String?
    /// 本窗口是否刚提交成功;驱动空态显示"提交成功"而非"没有改动"。
    /// 丢弃成功后重置——空态的成因变了,继续显示"提交成功"会造成误导。
    @State private var didCommit = false
    /// AI 生成提交信息;生成成功后直接覆盖输入框内容。
    @State private var isGeneratingMessage = false
    @State private var generateMessageTask: Task<Void, Never>?
    @State private var generateMessageErrorMessage: String?
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中任务
    /// (提交/丢弃/AI 生成/diff 加载)不得再把结果写进新仓库的状态。
    @State private var payloadGeneration = 0
    /// 提交信息输入区是否聚焦;聚焦时整枚胶囊描一圈主题色。
    @FocusState private var isCommitInputFocused: Bool
    /// 魔法棒 hover 态;hover 出淡灰圆底标示点击热区。
    @State private var isGenerateHovered = false

    private var isWorkingDirectorySource: Bool {
        if case .workingDirectory = payload.source { return true }
        return false
    }

    private var canDiscardChanges: Bool {
        isWorkingDirectorySource
    }

    /// 「展示所有行」的新侧全文取用:按来源解析策略(磁盘文件或历史 blob)后读取。
    ///
    /// 每个文件卡片在开关打开时惰性调用;分支对比的 head 是否当前分支决定新侧在磁盘
    /// 还是在 head 的 blob 里,diff 加载口径如此(`git diff <base>` vs `base..head`),
    /// 取全文须与之一致,因此每次现查当前分支而不是缓存。
    private var fullFileContentProvider: @Sendable (GitDiffEntry) async -> String? {
        let localPath = payload.localPath
        let source = payload.source
        let service = gitService
        return { entry in
            // 只有分支对比需要当前分支判断新侧在磁盘还是 blob;其余来源无需查询。
            var currentBranch: String?
            if case .compare = source {
                currentBranch = await service.currentBranch(in: localPath)
            }
            guard let strategy = DiffFullFileContentStrategy.resolve(
                source: source,
                currentBranch: currentBranch
            ) else { return nil }
            return await strategy.fileContent(entry: entry, localPath: localPath, gitService: service)
        }
    }

    private var canCommitChanges: Bool {
        canDiscardChanges
    }

    /// 有可提交内容且加载无异常时才展示提交栏;加载中/出错/空 diff 均隐藏。
    private var showsCommitBar: Bool {
        canCommitChanges && isLoading == false && errorMessage == nil && entries.isEmpty == false
    }

    private var trimmedCommitMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        DiffViewerView(
            repositoryName: payload.repositoryName,
            title: payload.title,
            diffs: entries,
            isLoading: isLoading,
            error: errorMessage,
            onRetry: { load() },
            onDiscardFile: canDiscardChanges ? { entry in pendingDiscardEntry = entry } : nil,
            emptyState: DiffWindowEmptyStateResolver.resolve(
                source: payload.source,
                didCommit: didCommit
            ),
            fullFileContent: fullFileContentProvider
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commitBar
        }
        .task { load() }
        .onChange(of: payload) { _, _ in
            // WindowGroup(for:) 复用同一窗口更换 payload 时 .task 不会重跑:
            // 重置自持状态并按新参数重新加载,避免显示旧仓库的 diff。
            // 必须先作废旧代际并取消进行中任务:旧仓库的提交/AI 生成回调
            // 会把"提交成功"文案、空输入框、错误弹窗带进新仓库窗口。
            payloadGeneration += 1
            discardTask?.cancel()
            discardTask = nil
            commitTask?.cancel()
            commitTask = nil
            generateMessageTask?.cancel()
            generateMessageTask = nil
            isDiscarding = false
            isCommitting = false
            isGeneratingMessage = false
            pendingDiscardEntry = nil
            discardErrorMessage = nil
            commitErrorMessage = nil
            generateMessageErrorMessage = nil
            commitMessage = ""
            didCommit = false
            load()
        }
        .onWindowBecomeKey {
            // 相等 payload 的 openWindow 只会聚焦已开窗口而不会重建内容,聚焦时刷新保证数据最新。
            // 进行中的提交/丢弃会自行 refresh,这里不再抢刷,避免与进行中任务抢刷新导致闪烁/滚动丢失。
            guard hasLoadedInitialData else { return }
            guard isCommitting == false, isDiscarding == false, isGeneratingMessage == false else { return }
            load(isRefresh: true)
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            discardTask?.cancel()
            discardTask = nil
            commitTask?.cancel()
            commitTask = nil
            generateMessageTask?.cancel()
            generateMessageTask = nil
        }
        .alert(
            pendingDiscardEntry.map { DiscardFileConfirmation.title(for: $0) } ?? "",
            isPresented: Binding(
                get: { pendingDiscardEntry != nil },
                set: { if $0 == false { pendingDiscardEntry = nil } }
            ),
            presenting: pendingDiscardEntry
        ) { entry in
            Button("丢弃", role: .destructive) {
                pendingDiscardEntry = nil
                discard(entry)
            }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(DiscardFileConfirmation.message(for: entry))
        }
        .alert(
            "丢弃改动失败",
            isPresented: Binding(
                get: { discardErrorMessage != nil },
                set: { if $0 == false { discardErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(discardErrorMessage ?? "")
        }
        .alert(
            "提交失败",
            isPresented: Binding(
                get: { commitErrorMessage != nil },
                set: { if $0 == false { commitErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(commitErrorMessage ?? "")
        }
        .alert(
            "生成提交信息失败",
            isPresented: Binding(
                get: { generateMessageErrorMessage != nil },
                set: { if $0 == false { generateMessageErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(generateMessageErrorMessage ?? "")
        }
    }

    /// 加载 diff。
    ///
    /// 首次加载与错误重试(`isRefresh == false`)清空内容展示骨架屏;
    /// 窗口聚焦刷新(`isRefresh == true`)保留旧内容静默换新,避免闪烁与滚动位置丢失。
    private func load(isRefresh: Bool = false) {
        loadTask?.cancel()
        errorMessage = nil
        if isRefresh == false {
            entries = []
            isLoading = true
        }
        let localPath = payload.localPath
        let service = gitService
        let source = payload.source
        let generation = payloadGeneration
        loadTask = Task { @MainActor in
            guard FileManager.default.fileExists(atPath: localPath) else {
                // payload 已更换(代际过期)时不得把旧仓库的错误写进新仓库视图。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.18)) {
                        errorMessage = "本地目录不存在：\(localPath)"
                        isLoading = false
                    }
                }
                return
            }
            let loaded: [GitDiffEntry]
            switch source {
            case .workingDirectory:
                loaded = await service.diffWorkingDirectory(in: localPath)
            case .commit(let hash):
                loaded = await service.diffCommit(hash: hash, in: localPath)
            case .compare(let base, let head):
                guard let head, head.isEmpty == false else {
                    guard !Task.isCancelled, generation == payloadGeneration else { return }
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.18)) {
                            errorMessage = "当前仓库未检出分支，无法进行分支对比"
                            isLoading = false
                        }
                    }
                    return
                }
                loaded = await service.diffBranches(base: base, head: head, in: localPath)
            }
            guard !Task.isCancelled, generation == payloadGeneration else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    entries = loaded
                    isLoading = false
                    hasLoadedInitialData = true
                }
            }
        }
    }

    /// 执行单文件丢弃:成功后静默刷新列表,失败弹窗提示(不打断已展示的 diff 内容)。
    private func discard(_ entry: GitDiffEntry) {
        guard isDiscarding == false else { return }
        isDiscarding = true
        let service = gitService
        let directory = payload.localPath
        let filePath = entry.filePath
        let generation = payloadGeneration
        discardTask = Task { @MainActor in
            // defer 复位:即使任务在 await 返回后被取消(onDisappear),退出闭包时
            // 也能把 isDiscarding 归位,避免永久卡在进行中。
            defer { isDiscarding = false }
            do {
                try await service.discardChanges(filePath: filePath, in: directory)
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                didCommit = false
                load(isRefresh: true)
            } catch {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                discardErrorMessage = error.localizedDescription
            }
        }
    }

    /// 提交全部工作区改动(与窗口展示范围一致,含 untracked):成功后清空输入、空态切换为
    /// "提交成功"并静默刷新,失败弹窗提示且保留已输入的提交信息。
    private func commit() {
        guard isCommitting == false, trimmedCommitMessage.isEmpty == false else { return }
        isCommitting = true
        let service = gitService
        let directory = payload.localPath
        let message = trimmedCommitMessage
        let generation = payloadGeneration
        commitTask = Task { @MainActor in
            // defer 复位:即使任务在 await 返回后被取消(onDisappear),退出闭包时
            // 也能把 isCommitting 归位,避免永久卡在进行中。
            defer { isCommitting = false }
            do {
                try await service.commitAllChanges(message: message, in: directory)
                // payload 已更换时不得把"提交成功"/清空输入框带到新仓库窗口。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                commitMessage = ""
                didCommit = true
                load(isRefresh: true)
            } catch {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                commitErrorMessage = error.localizedDescription
            }
        }
    }

    /// 请求 AI 生成提交信息并填入输入框(覆盖已有内容,便于反复重试换结果);
    /// 失败弹窗提示且不影响已输入内容。
    private func generateCommitMessage() {
        guard isGeneratingMessage == false, isCommitting == false else { return }
        isGeneratingMessage = true
        generateMessageErrorMessage = nil
        let service = aiCommitService
        let gitService = gitService
        let directory = payload.localPath
        let diffs = entries
        let generation = payloadGeneration
        generateMessageTask = Task { @MainActor in
            // defer 复位:与 discard/commit 保持一致。此前三个分支各写一次复位,
            // 取消路径(onDisappear 已 cancel 任务)会把 isGeneratingMessage 永久留在 true。
            defer { isGeneratingMessage = false }
            // 先取最近提交主题作为语言与风格参考,失败时静默降级为空列表。
            let recentSubjects = await gitService
                .recentCommits(in: directory, count: AICommitPromptBuilder.recentCommitSubjectCount)
                .map(\.subject)
            do {
                let message = try await service.generateCommitMessage(
                    diffs: diffs,
                    recentCommitSubjects: recentSubjects
                )
                // payload 已更换时不得把旧仓库的生成结果填进新仓库的输入框。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                commitMessage = message
            } catch {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                generateMessageErrorMessage = Self.localizedAIFailureMessage(error)
            }
        }
    }

    /// 把面向用户的失败文案兜底为中文。
    ///
    /// git 错误与 `AICommitMessageError` 已本地化,但 `URLError`(离线/超时/DNS)
    /// 是系统英文文案,直接展示会出现「生成提交信息失败:The Internet connection
    /// appears to be offline.」这种中英混排。
    private static func localizedAIFailureMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用，请检查网络连接后重试"
            case .timedOut:
                return "请求超时，请稍后重试"
            case .cannotFindHost, .dnsLookupFailed:
                return "无法解析 AI 服务地址，请检查配置"
            case .cannotConnectToHost:
                return "无法连接 AI 服务，请检查地址与网络"
            case .badServerResponse, .cannotParseResponse:
                return "AI 服务返回的内容无法解析"
            case .userCancelledAuthentication, .userAuthenticationRequired:
                return "AI 服务认证失败，请检查 API Key"
            default:
                return "网络请求失败（错误码 \(urlError.errorCode)）"
            }
        }
        return error.localizedDescription
    }

    /// 底部提交栏:胶囊浮岛式——整条收进一枚白色圆角胶囊;魔法棒(AI 生成)在输入区左内侧,右端胶囊提交钮。
    ///
    /// 用单行 TextField(macOS 上 `axis: .vertical` 的 onSubmit 不触发,回车提交会失效);
    /// 无边框输入用纯文本样式 + 整枚胶囊描边(常态浅灰/聚焦主题色)。
    @ViewBuilder
    private var commitBar: some View {
        if showsCommitBar {
            HStack(spacing: 0) {
                generateButton
                commitMessageField
                Button("提交", action: commit)
                    .buttonStyle(PillCommitButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedCommitMessage.isEmpty || isCommitting)
            }
            .padding(4)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: Capsule()
            )
            .overlay {
                // 常态描浅灰边,保证不聚焦也能看出这里是输入区;聚焦时换主题色环。
                if isCommitInputFocused {
                    Capsule()
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                } else {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// 胶囊内输入区:魔法棒右侧的纯文本输入,生成中展示打字机提示(逐字打出 + 闪烁光标)。
    private var commitMessageField: some View {
        TextField(isGeneratingMessage ? "" : "输入提交信息…", text: $commitMessage)
            .textFieldStyle(.plain)
            .focused($isCommitInputFocused)
            .onSubmit(commit)
            .disabled(isCommitting)
            .padding(.leading, 2)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity)
            .overlay {
                if isGeneratingMessage, commitMessage.isEmpty {
                    GeneratingTypewriterText()
                }
            }
    }

    /// 魔法棒(AI 生成提交信息,可反复点击重试):输入区左内侧前缀图标,主题色显眼标注。
    /// 生成中星星逐个闪烁 + 轻微摆动,周围冒星尘(见 GeneratingStardust);提交期间降透明度禁点。
    private var generateButton: some View {
        Button {
            generateCommitMessage()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    options: .repeating,
                    isActive: isGeneratingMessage
                )
                .rotationEffect(.degrees(isGeneratingMessage ? 10 : 0))
                .animation(
                    isGeneratingMessage
                        ? .easeInOut(duration: 0.35).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: isGeneratingMessage
                )
                .frame(width: 26, height: 26)
                .background(
                    isGenerateHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: Circle()
                )
                .opacity(isCommitting ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isGeneratingMessage || isCommitting)
        .padding(.leading, 5)
        .overlay {
            if isGeneratingMessage {
                GeneratingStardust()
            }
        }
        .onHover { isGenerateHovered = $0 }
        .ccspaceQuickHelp("AI 生成提交信息，可反复点击重新生成", providesLabel: true)
    }
}

/// AI 生成中的星尘粒子:魔法棒周围持续冒出细小星尘(浮现→上浮→消散),三颗按相位错峰。
///
/// 用 TimelineView 按真实时钟计算相位(macOS 14 无 KeyframeAnimator/PhaseAnimator,
/// 多段关键帧用时钟驱动最稳):仅生成期间插入视图树,移除即自动停帧;
/// 单周期 1.5s,透明度走抛物线(起止 0、中段峰值),上浮 3→−11pt。
private struct GeneratingStardust: View {
    /// 单个粒子的起始偏移(相对魔法棒中心)与错峰相位。
    private struct Seed {
        let x: CGFloat
        let y: CGFloat
        let phase: Double
    }

    private static let cycle: Double = 1.5
    private static let seeds: [Seed] = [
        Seed(x: -11, y: -6, phase: 0),
        Seed(x: 11, y: -3, phase: 1.0 / 3.0),
        Seed(x: -4, y: -12, phase: 2.0 / 3.0),
    ]

    /// 粒子相位进度(0..<1):由当前时刻与错峰相位推出。
    private static func progress(at date: Date, phase: Double) -> Double {
        ((date.timeIntervalSinceReferenceDate / cycle) + phase)
            .truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation) { context in
            ZStack {
                ForEach(Array(Self.seeds.enumerated()), id: \.offset) { _, seed in
                    let p = Self.progress(at: context.date, phase: seed.phase)
                    Image(systemName: "sparkle")
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .opacity(4 * p * (1 - p))
                        .scaleEffect(0.55 + 0.45 * min(p * 2.5, 1))
                        .offset(x: seed.x, y: seed.y + 3 - 14 * p)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// AI 生成中的打字机提示:「AI 正在生成…」逐字打出→停顿→回退消隐,循环;尾部主题色光标闪烁。
///
/// 用 .task 长循环驱动(勿在 body 内建 Timer):仅生成期间插入视图树,
/// 任务随视图移除自动取消;生成完成时真文案直接替换,衔接自然。
private struct GeneratingTypewriterText: View {
    private static let fullText = "AI 正在生成…"
    @State private var visibleCount = 0

    var body: some View {
        HStack(spacing: 1) {
            Text(Self.fullText.prefix(visibleCount))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            BlinkingCaret()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .task {
            while Task.isCancelled == false {
                for count in 0...Self.fullText.count {
                    visibleCount = count
                    try? await Task.sleep(for: .milliseconds(90))
                }
                try? await Task.sleep(for: .milliseconds(800))
                for count in stride(from: Self.fullText.count, through: 0, by: -1) {
                    visibleCount = count
                    try? await Task.sleep(for: .milliseconds(40))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

/// 打字机尾部的闪烁光标:1.5pt 主题色竖线,0.5s 一闪。
private struct BlinkingCaret: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5, height: 15)
            .opacity(visible ? 1 : 0)
            .task {
                while Task.isCancelled == false {
                    try? await Task.sleep(for: .milliseconds(500))
                    visible.toggle()
                }
            }
    }
}

/// 监听宿主窗口成为 key 窗口,用于重新聚焦 diff 窗口时刷新数据。
private struct WindowBecomeKeyObserver: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.action = action
    }

    final class ObserverView: NSView {
        var action: (() -> Void)?
        private var observer: (token: NSObjectProtocol, window: NSWindow)?

        override func viewDidMoveToWindow() {
            if let observer {
                NotificationCenter.default.removeObserver(
                    observer.token,
                    name: NSWindow.didBecomeKeyNotification,
                    object: observer.window
                )
                self.observer = nil
            }
            guard let window else { return }
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.action?()
                }
            }
            observer = (token, window)
        }
    }
}

internal extension View {
    /// 宿主窗口每次成为 key 窗口时触发(窗口首次打开时也会触发一次)。
    /// Diff / 提交记录 / 分支比较等独立窗口共用的聚焦刷新入口。
    func onWindowBecomeKey(action: @escaping () -> Void) -> some View {
        background(WindowBecomeKeyObserver(action: action))
    }
}

/// 胶囊提交按钮:主题色胶囊,贴合外层胶囊浮岛的曲率。
private struct PillCommitButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 27)
            .background(
                Capsule().fill(Color.accentColor)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
