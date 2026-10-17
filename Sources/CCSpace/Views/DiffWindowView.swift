import SwiftUI

/// Diff 独立窗口的打开参数。
///
/// 作为 `WindowGroup(for:)` 的 value:相等 payload 复用已打开的窗口(聚焦时刷新),
/// 不同 payload 各开一个窗口,可与主窗口并行操作。
extension DiffWindowPayload.Source {
    /// View 侧 payload 来源 → Service 层来源。
    ///
    /// 映射放在 Views 一侧:`RepositoryWindowContext` 反过来依赖 `DiffWindowPayload`
    /// 就是层倒置(Service 不该知道窗口的路由载荷类型)。
    var diffSource: RepositoryWindowContext.DiffSource {
        switch self {
        case .workingDirectory: return .workingDirectory
        case .commit(let hash): return .commit(hash: hash)
        case .compare(let base, let head): return .compare(base: base, head: head)
        }
    }
}

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
    /// git 取数一律经 Service 层的上下文:View 不再直接持有 `GitServicing`。
    /// 此前 diff 三来源、detached HEAD 探测、最近提交主题都在本视图里直接调 git,
    /// 违反 AGENTS.md 的依赖方向(View 不直接调 git,必须经 Store/Coordinator)。
    @StateObject private var context: RepositoryWindowContext
    /// 破坏性写(丢弃/提交)的唯一入口:协调器内部持 per-path 锁与后台 pull/push 互斥。
    let syncCoordinator: SyncCoordinator
    /// 目录存在性探测:View 不直接碰 FileManager,统一走 FileSystemService(含 isDirectory 校验)。
    let fileSystemService: FileSystemServicing

    init(
        payload: DiffWindowPayload,
        gitService: GitServicing,
        syncCoordinator: SyncCoordinator,
        fileSystemService: FileSystemServicing
    ) {
        self.payload = payload
        self._context = StateObject(wrappedValue: RepositoryWindowContext(gitService: gitService))
        self.syncCoordinator = syncCoordinator
        self.fileSystemService = fileSystemService
    }

    private var diffSource: RepositoryWindowContext.DiffSource { payload.source.diffSource }

    @State private var entries: [GitDiffEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?
    /// 首次加载流程是否已结束(无论成败);用于跳过窗口刚打开时的 becomeKey 通知,
    /// 避免重复加载。只在成功路径置位会让首载瞬时失败后聚焦刷新永久停摆。
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
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中任务
    /// (提交/丢弃/diff 加载)不得再把结果写进新仓库的状态。
    @State private var payloadGeneration = 0
    /// 提交信息输入区是否聚焦;聚焦时整枚胶囊描一圈主题色。
    @FocusState private var isCommitInputFocused: Bool

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
    ///
    /// 读磁盘文件 / 解码 git cat-file 输出是重活:本闭包由 DiffViewerView 的
    /// @MainActor 展开流程调用,不显式挪走就会同步跑在主线程上,故策略执行
    /// 包进 `Task.detached`(与展开纯函数同一约定)。
    private var fullFileContentProvider: @Sendable (GitDiffEntry) async -> String? {
        let localPath = payload.localPath
        let diffSource = self.diffSource
        let context = _context.wrappedValue
        // 当前分支探测、策略解析与 blob/磁盘读取全部在 Service 层完成
        // (重 IO 仍在 context 内部包进 Task.detached)。
        return { entry in
            await context.fullFileContent(entry: entry, directory: localPath, source: diffSource)
        }
    }

    /// 有可提交内容且加载无异常时才展示提交栏;加载中/出错/空 diff 均隐藏。
    private var showsCommitBar: Bool {
        canDiscardChanges && isLoading == false && errorMessage == nil && entries.isEmpty == false
    }

    /// 未跟踪文件达到展示上限时的提示;仅工作区来源需要(其余来源没有 untracked 概念)。
    /// 列表只展示前 N 个未跟踪文件,而提交会覆盖全部改动,不把差别说出来会误导用户。
    private var untrackedTruncationNotice: String? {
        guard isWorkingDirectorySource, isLoading == false, errorMessage == nil else { return nil }
        return DiffWindowUntrackedDisplay.truncationNotice(for: entries)
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
            // 必须先作废旧代际并取消进行中任务:旧仓库的提交/丢弃回调
            // 会把"提交成功"文案、空输入框、错误弹窗带进新仓库窗口。
            payloadGeneration += 1
            discardTask?.cancel()
            discardTask = nil
            commitTask?.cancel()
            commitTask = nil
            isDiscarding = false
            isCommitting = false
            pendingDiscardEntry = nil
            discardErrorMessage = nil
            commitErrorMessage = nil
            commitMessage = ""
            didCommit = false
            // 复用窗口换新 payload:作废"首载已完成"标记,防止加载期间一次
            // 聚焦事件抢跑 load(isRefresh: true) 与 onChange 自己发起的 load() 并发。
            hasLoadedInitialData = false
            load()
        }
        .onWindowBecomeKey {
            // 相等 payload 的 openWindow 只会聚焦已开窗口而不会重建内容,聚焦时刷新保证数据最新。
            // 进行中的提交/丢弃会自行 refresh,这里不再抢刷,避免与进行中任务抢刷新导致闪烁/滚动丢失。
            // 守卫只等"首次加载流程结束",失败同样算结束:否则首载瞬时失败后聚焦刷新就再也进不来。
            guard hasLoadedInitialData else { return }
            guard isCommitting == false, isDiscarding == false else { return }
            load(isRefresh: true)
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            discardTask?.cancel()
            discardTask = nil
            commitTask?.cancel()
            commitTask = nil
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
    }

    /// 加载 diff。
    ///
    /// 首次加载与错误重试(`isRefresh == false`)清空内容展示骨架屏;
    /// 窗口聚焦刷新(`isRefresh == true`)保留旧内容静默换新,避免闪烁与滚动位置丢失。
    /// 每条终止落笔路径(成功与各条报错)都要置 `hasLoadedInitialData`:
    /// 首载瞬时失败若不落笔,聚焦自动刷新的守卫会永远过不去,窗口就此不再更新。
    private func load(isRefresh: Bool = false) {
        loadTask?.cancel()
        errorMessage = nil
        if isRefresh == false {
            entries = []
            isLoading = true
        }
        let localPath = payload.localPath
        let context = _context.wrappedValue
        let source = payload.source
        let diffSource = self.diffSource
        let fileSystem = fileSystemService
        let generation = payloadGeneration
        loadTask = Task { @MainActor in
            // 目录存在性走 FileSystemService.directoryExists(含 isDirectory 校验),
            // View 不直接碰 FileManager。单次 stat 开销可忽略,留在主线程执行。
            guard fileSystem.directoryExists(at: localPath) else {
                // payload 已更换(代际过期)时不得把旧仓库的错误写进新仓库视图。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    errorMessage = "本地目录不存在：\(localPath)"
                    isLoading = false
                    hasLoadedInitialData = true
                }
                return
            }
            // 分支对比来源未检出分支(detached HEAD)是硬失败:给专属文案而非通用报错。
            // 只校验、不再把 head 往下传:三种来源的 git 调用差异已由
            // RepositoryWindowContext.loadDiff 收敛,payload 里的 head 直接参与。
            if case .compare(_, let head) = source {
                guard let head, head.isEmpty == false else {
                    guard !Task.isCancelled, generation == payloadGeneration else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        errorMessage = "当前仓库未检出分支，无法进行分支对比"
                        isLoading = false
                        hasLoadedInitialData = true
                    }
                    return
                }
            }
            let loaded: [GitDiffEntry]
            do {
                // 三种来源的 git 调用差异由 Service 层收敛,View 侧不再 switch 调 git。
                loaded = try await context.loadDiff(
                    directory: localPath,
                    source: diffSource
                )
            } catch is CancellationError {
                // 取消不当作失败:payload 更换/窗口关闭时静默停止,不污染新仓库的错误态。
                return
            } catch {
                // payload 已更换时不得把旧仓库的错误写进新仓库视图。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    errorMessage = RepositoryWindowContext.localizedDiffFailureMessage(error)
                    isLoading = false
                    hasLoadedInitialData = true
                }
                return
            }
            guard !Task.isCancelled, generation == payloadGeneration else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                entries = loaded
                isLoading = false
                hasLoadedInitialData = true
            }
        }
    }

    /// 执行单文件丢弃:成功后静默刷新列表,失败弹窗提示(不打断已展示的 diff 内容)。
    private func discard(_ entry: GitDiffEntry) {
        guard isDiscarding == false else { return }
        isDiscarding = true
        let coordinator = syncCoordinator
        let directory = payload.localPath
        let filePath = entry.filePath
        let generation = payloadGeneration
        discardTask = Task { @MainActor in
            // defer 复位:即使任务在 await 返回后被取消(onDisappear),退出闭包时
            // 也能把 isDiscarding 归位,避免永久卡在进行中。
            defer { isDiscarding = false }
            do {
                try await coordinator.discardFileChanges(filePath: filePath, in: directory)
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                didCommit = false
                load(isRefresh: true)
            } catch {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                discardErrorMessage = UserFacingError.message(for: error)
            }
        }
    }

    /// 提交全部工作区改动(走 `git add --all`,范围等于整个工作区,可能大于列表展示范围——
    /// 未跟踪文件触顶时列表只展示前若干个,差别说理由提交栏上方的提示给出):
    /// 成功后清空输入、空态切换为"提交成功"并静默刷新,失败弹窗提示且保留已输入的提交信息。
    private func commit() {
        guard isCommitting == false, trimmedCommitMessage.isEmpty == false else { return }
        isCommitting = true
        let coordinator = syncCoordinator
        let directory = payload.localPath
        let message = trimmedCommitMessage
        let generation = payloadGeneration
        commitTask = Task { @MainActor in
            // defer 复位:即使任务在 await 返回后被取消(onDisappear),退出闭包时
            // 也能把 isCommitting 归位,避免永久卡在进行中。
            defer { isCommitting = false }
            do {
                try await coordinator.commitAllChanges(message: message, in: directory)
                // payload 已更换时不得把"提交成功"/清空输入框带到新仓库窗口。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                commitMessage = ""
                didCommit = true
                load(isRefresh: true)
            } catch {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                commitErrorMessage = UserFacingError.message(for: error)
            }
        }
    }

    /// 底部提交栏:胶囊浮岛式——整条收进一枚白色圆角胶囊,右端胶囊提交钮。
    ///
    /// 用单行 TextField(macOS 上 `axis: .vertical` 的 onSubmit 不触发,回车提交会失效);
    /// 无边框输入用纯文本样式 + 整枚胶囊描边(常态浅灰/聚焦主题色)。
    /// 未跟踪文件达到展示上限时,胶囊上方加一行说明:提交范围大于列表展示范围。
    @ViewBuilder
    private var commitBar: some View {
        if showsCommitBar {
            VStack(spacing: 4) {
                if let untrackedTruncationNotice {
                    Label(untrackedTruncationNotice, systemImage: "info.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 0) {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// 胶囊内输入区:纯文本输入。
    private var commitMessageField: some View {
        TextField("输入提交信息…", text: $commitMessage)
            .textFieldStyle(.plain)
            .focused($isCommitInputFocused)
            .onSubmit(commit)
            .disabled(isCommitting)
            .padding(.leading, 2)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity)
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
            removeExistingObserver()
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

        // SwiftUI 释放承载视图不保证回调 viewDidMoveToWindow(nil):若不在 deinit 兜底
        // 注销,每次 Diff/提交记录/分支比较窗口开关都会残留一条 block 注册(经典
        // AppKit block-observer 泄漏),多个窗口类型共用时按窗口数累积。
        deinit {
            // AppKit 视图 dealloc 发生在主线程(对象由主线程释放),
            // assumeIsolated 只是向编译器固化这一既有事实,非运行时赌注。
            MainActor.assumeIsolated {
                removeExistingObserver()
            }
        }

        private func removeExistingObserver() {
            guard let observer else { return }
            NotificationCenter.default.removeObserver(
                observer.token,
                name: NSWindow.didBecomeKeyNotification,
                object: observer.window
            )
            self.observer = nil
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
