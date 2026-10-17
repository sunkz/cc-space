import SwiftUI

/// 作为 `WindowGroup(for:)` 的 value:相等 payload 复用已打开的窗口(聚焦时刷新),
/// 不同 payload 各开一个窗口,可与主窗口并行操作。
extension DiffWindowPayload.Source {
    /// 映射放在 Views 一侧:`RepositoryWindowContext` 反过来依赖 `DiffWindowPayload`
    /// 就是层倒置(Service 不该知道窗口的路由载荷类型)。
    var diffSource: RepositoryWindowContext.DiffSource {
        switch self {
        case .workingDirectory: return .workingDirectory
        case .commit(let hash): return .commit(hash: hash)
        }
    }
}

struct DiffWindowPayload: Codable, Hashable {
    enum Source: Codable, Hashable {
        case workingDirectory
        case commit(hash: String)
    }

    let repositoryName: String
    let localPath: String
    let title: String
    let source: Source
}

/// 非模态窗口:加载与刷新状态由本视图自持,与触发它的仓库行视图生命周期解耦。
struct DiffWindowView: View {
    let payload: DiffWindowPayload
    /// git 取数一律经 Service 层的上下文,View 不直接持有 `GitServicing`、不调 git。
    @StateObject private var context: RepositoryWindowContext
    /// 破坏性写(丢弃/提交)的唯一入口:协调器内部持 per-path 锁与后台 pull/push 互斥。
    let syncCoordinator: SyncCoordinator
    /// 目录存在性探测统一走 FileSystemService(含 isDirectory 校验),View 不直接碰 FileManager。
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
    /// 首次加载流程是否已结束(无论成败):跳过窗口刚打开时的 becomeKey 通知,避免重复加载。
    /// 只在成功路径置位会让首载瞬时失败后聚焦刷新永久停摆。
    @State private var hasLoadedInitialData = false
    @State private var pendingDiscardEntry: GitDiffEntry?
    @State private var discardErrorMessage: String?
    @State private var isDiscarding = false
    @State private var discardTask: Task<Void, Never>?
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var commitTask: Task<Void, Never>?
    @State private var commitErrorMessage: String?
    /// 本窗口是否刚提交成功;丢弃成功后要重置——空态成因变了,继续显示"提交成功"会误导。
    @State private var didCommit = false
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中任务
    /// (提交/丢弃/diff 加载)不得再把结果写进新仓库的状态。
    @State private var payloadGeneration = 0
    @FocusState private var isCommitInputFocused: Bool

    private var isWorkingDirectorySource: Bool {
        if case .workingDirectory = payload.source { return true }
        return false
    }

    private var canDiscardChanges: Bool {
        isWorkingDirectorySource
    }

    /// 「展示所有行」新侧全文:取数口径必须与 diff 加载一致(head 是否当前分支决定读磁盘还是 blob),
    /// 故每次现查当前分支不缓存;读盘/解码重活由本闭包包进 `Task.detached`,不跑在调用方主线程上。
    private var fullFileContentProvider: @Sendable (GitDiffEntry) async -> String? {
        let localPath = payload.localPath
        let diffSource = self.diffSource
        let context = _context.wrappedValue
        return { entry in
            await context.fullFileContent(entry: entry, directory: localPath, source: diffSource)
        }
    }

    private var showsCommitBar: Bool {
        canDiscardChanges && isLoading == false && errorMessage == nil && entries.isEmpty == false
    }

    /// 未跟踪文件达到展示上限时的提示;仅工作区来源有 untracked 概念。
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
            // WindowGroup(for:) 复用同一窗口更换 payload 时 .task 不会重跑:必须先作废旧代际并取消
            // 在途提交/丢弃,否则旧仓库的回调会把"提交成功"文案、空输入框、错误弹窗带进新仓库窗口。
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
            // 作废"首载已完成"标记:否则加载期间一次聚焦事件会抢跑 load(isRefresh: true),
            // 与 onChange 自己发起的 load() 并发。
            hasLoadedInitialData = false
            load()
        }
        .onWindowBecomeKey {
            // 相等 payload 的 openWindow 只聚焦已开窗口、不重建内容,故聚焦时刷新;
            // 进行中的提交/丢弃会自行 refresh,这里不抢刷,避免闪烁与滚动位置丢失。
            // 守卫只等"首载流程结束",失败同样算结束:否则首载瞬时失败后聚焦刷新就再也进不来。
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

    /// 首载与重试(`isRefresh == false`)清空内容展示骨架屏;聚焦刷新保留旧内容静默换新,避免闪烁与滚动丢失。
    /// 每条终止落笔路径(成功与各条报错)都要置 `hasLoadedInitialData`,否则聚焦自动刷新永久停摆。
    private func load(isRefresh: Bool = false) {
        loadTask?.cancel()
        errorMessage = nil
        if isRefresh == false {
            entries = []
            isLoading = true
        }
        let localPath = payload.localPath
        let context = _context.wrappedValue
        let diffSource = self.diffSource
        let fileSystem = fileSystemService
        let generation = payloadGeneration
        loadTask = Task { @MainActor in
            // 单次 stat 开销可忽略,目录存在性留在主线程执行。
            guard fileSystem.directoryExists(at: localPath) else {
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    errorMessage = "本地目录不存在：\(localPath)"
                    isLoading = false
                    hasLoadedInitialData = true
                }
                return
            }
            let loaded: [GitDiffEntry]
            do {
                loaded = try await context.loadDiff(
                    directory: localPath,
                    source: diffSource
                )
            } catch is CancellationError {
                // 取消不当作失败:payload 更换/窗口关闭时静默停止,不污染新仓库的错误态。
                return
            } catch {
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

    /// 单文件丢弃:成功后静默刷新列表,失败弹窗(不打断已展示的 diff 内容)。
    private func discard(_ entry: GitDiffEntry) {
        guard isDiscarding == false else { return }
        isDiscarding = true
        let coordinator = syncCoordinator
        let directory = payload.localPath
        let filePath = entry.filePath
        let generation = payloadGeneration
        discardTask = Task { @MainActor in
            // defer 复位:任务在 await 返回后才被取消(onDisappear)时,退出闭包仍能把标志归位。
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

    /// 提交全部工作区改动:走 `git add --all`,范围等于整个工作区、可能大于列表展示范围
    /// (差别说理由提交栏上方的提示给出);失败时保留已输入的提交信息。
    private func commit() {
        guard isCommitting == false, trimmedCommitMessage.isEmpty == false else { return }
        isCommitting = true
        let coordinator = syncCoordinator
        let directory = payload.localPath
        let message = trimmedCommitMessage
        let generation = payloadGeneration
        commitTask = Task { @MainActor in
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

    /// 底部提交栏:胶囊浮岛式,整条收进一枚圆角胶囊、右端胶囊提交钮。
    /// 用单行 TextField:macOS 上 `axis: .vertical` 的 onSubmit 不触发,回车提交会失效。
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

        // SwiftUI 释放承载视图不保证回调 viewDidMoveToWindow(nil):不在 deinit 兜底注销,
        // 每次窗口开关都会残留一条 block 注册(经典 AppKit block-observer 泄漏),按窗口数累积。
        deinit {
            // AppKit 视图 dealloc 发生在主线程(对象由主线程释放),assumeIsolated 只是向编译器固化这一既有事实。
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
    /// 宿主窗口每次成为 key 窗口时触发,窗口首次打开时也会触发一次(Diff/提交记录/分支比较窗口共用)。
    func onWindowBecomeKey(action: @escaping () -> Void) -> some View {
        background(WindowBecomeKeyObserver(action: action))
    }
}

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
