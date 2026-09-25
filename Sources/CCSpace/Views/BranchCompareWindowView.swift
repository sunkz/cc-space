import SwiftUI

/// 分支比较独立窗口的打开参数(与 Diff/提交记录窗口同一套 payload 模式)。
/// base/head 为 nil 时由窗口在加载分支上下文后兜底解析(base=默认分支,head=当前分支)。
struct BranchCompareWindowPayload: Codable, Hashable {
    let repositoryName: String
    let localPath: String
    var base: String? = nil
    var head: String? = nil
}

/// 分支比较窗口:from/to 两侧分支都可切换(复用分支弹窗的对比模式做选择器),
/// 支持一键互换,头部展示两侧独有提交数,下方复用 DiffViewerView 展示文件级差异。
struct BranchCompareWindowView: View {
    let payload: BranchCompareWindowPayload
    let gitService: GitServicing

    @State private var baseRef: String?
    @State private var headRef: String?
    @State private var localBranches: [String] = []
    @State private var remoteTrackingBranches: [String] = []
    @State private var entries: [GitDiffEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var divergence: GitRefDivergence?
    @State private var loadTask: Task<Void, Never>?
    @State private var contextTask: Task<Void, Never>?
    /// 首次加载是否已完成;跳过刚打开时的 becomeKey 重叠(与 Diff/提交记录窗口同一模式)。
    @State private var hasLoadedInitialData = false
    @State private var showingBasePicker = false
    @State private var showingHeadPicker = false
    /// 分支上下文加载代际号:每次 loadBranchContext 递增,旧任务写回前比对,
    /// 防止"isCancelled 检查通过但落笔晚于新任务"造成旧结果覆盖新结果。
    @State private var contextRequestID = 0
    @State private var diffRequestID = 0

    /// 与 Diff 窗口同构的来源描述:驱动 diff 加载与"展示所有行"的新侧策略。
    private var source: DiffWindowPayload.Source {
        .compare(base: baseRef ?? "", head: headRef)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            diffViewer
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 460, idealHeight: 600)
        .toolbar {
            // from/to 分支 chip 与互换按钮收进同一个 ToolbarItem 的 HStack:
            // 分成三个 item 时系统会在 item 间插入较宽默认间距,分支名显得离
            // 互换图标太远;合成一个 item 后由 spacing 精确控制贴合感。
            // 仓库名与"分支比较"副标题由内层 DiffViewerView 的 navigationTitle 提供。
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                    refChip(ref: baseRef, fallback: "默认分支") { showingBasePicker = true }
                        .padding(.leading, 6)
                        .ccspacePopover(isPresented: $showingBasePicker, arrowEdge: .bottom) {
                            branchPicker(currentSelection: baseRef) { ref in
                                baseRef = ref
                                reloadDiff()
                            }
                        }
                    Button {
                        swapRefs()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(baseRef == nil || headRef == nil)
                    .ccspaceQuickHelp("互换比较方向")
                    .accessibilityLabel("互换比较方向")
                    refChip(ref: headRef, fallback: "当前分支") { showingHeadPicker = true }
                        .padding(.trailing, 6)
                        .ccspacePopover(isPresented: $showingHeadPicker, arrowEdge: .bottom) {
                            branchPicker(currentSelection: headRef) { ref in
                                headRef = ref
                                reloadDiff()
                            }
                        }
                }
            }
        }
        .onAppear {
            baseRef = payload.base
            headRef = payload.head
            loadBranchContext()
            reloadDiff()
        }
        .onDisappear {
            loadTask?.cancel()
            contextTask?.cancel()
        }
        .onWindowBecomeKey {
            // 相等 payload 的 openWindow 只聚焦已开窗口不重建内容:聚焦时刷新上下文与差异;
            // 首开的 becomeKey 与 onAppear 重叠,由 hasLoadedInitialData 跳过。
            guard hasLoadedInitialData else { return }
            loadBranchContext()
            reloadDiff()
        }
    }

    // MARK: - 顶部信息条(分歧统计 + 刷新;分支选择已上移标题栏)

    private var controls: some View {
        HStack(spacing: 8) {
            if let divergence {
                Text("仅「\(baseRef ?? "")」\(divergence.baseOnlyCount) 提交 · 仅「\(headRef ?? "")」\(divergence.headOnlyCount) 提交")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("两侧各自独有的提交数;相等表示两分支内容一致")
            }
            Spacer()
            Button {
                loadBranchContext()
                reloadDiff()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("刷新")
            .accessibilityLabel("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 比较侧分支 chip:与提交记录窗口的分支 pill 同款蓝色样式,点击弹出分支选择器。
    /// 不设宽度上限:pill 随分支名长度自适应展示全名。
    private func refChip(ref: String?, fallback: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RepositoryBranchPill(title: ref ?? fallback, showsIcon: false)
        }
        .buttonStyle(.plain)
        .ccspaceQuickHelp(ref ?? fallback)
    }

    /// 分支选择器:复用分支弹窗的对比模式骨架(本地/远端页签 + 搜索),
    /// 选中回调收展示名(本地裸名 / origin/ 前缀名,均为 git 可用引用)。
    /// 锚点在系统标题栏上:弹窗内容会继承锚点环境的大字号,显式钉回常规尺寸
    /// (与提交记录窗口的分支选择器同一处理)。
    private func branchPicker(currentSelection: String?, onSelect: @escaping (String) -> Void) -> some View {
        BranchListPopoverView(
            currentBranch: currentSelection,
            localBranches: localBranches,
            remoteTrackingBranches: remoteTrackingBranches,
            pickHint: "点击选择该分支",
            onCompare: { ref in
                onSelect(ref)
            }
        )
        .environment(\.controlSize, .regular)
        .font(.body)
    }

    // MARK: - Diff 内容

    private var diffViewer: some View {
        DiffViewerView(
            repositoryName: payload.repositoryName,
            title: "分支比较",
            diffs: entries,
            isLoading: isLoading,
            error: errorMessage,
            onRetry: { reloadDiff() },
            emptyState: .noChanges,
            fullFileContent: fullFileContentProvider,
            toolbarLeadingSeparator: true
        )
    }

    /// 「展示所有行」新侧全文策略:与 Diff 窗口同源——head 是否当前分支决定读磁盘还是 blob。
    private var fullFileContentProvider: @Sendable (GitDiffEntry) async -> String? {
        let localPath = payload.localPath
        let source = source
        let service = gitService
        return { entry in
            let currentBranch = await service.currentBranch(in: localPath)
            guard let strategy = DiffFullFileContentStrategy.resolve(
                source: source,
                currentBranch: currentBranch
            ) else { return nil }
            return await strategy.fileContent(entry: entry, localPath: localPath, gitService: service)
        }
    }

    // MARK: - 加载

    /// 分支名单/远端跟踪分支:供两侧选择器;顺带兜底解析未提供的初始 base/head。
    private func loadBranchContext() {
        contextTask?.cancel()
        contextRequestID += 1
        let requestID = contextRequestID
        let path = payload.localPath
        let service = gitService
        contextTask = Task {
            async let branchesTask = service.branches(in: path)
            async let remoteTask = service.remoteTrackingBranches(in: path)
            async let currentTask = service.currentBranch(in: path)
            async let defaultTask = service.defaultBranch(in: path)
            let branches = await branchesTask
            let remote = await remoteTask
            let current = await currentTask
            let defaultBranch = await defaultTask
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // isCancelled 检查与新任务发起之间仍可能隔着一次挂起:
                // 落笔前再比对代际号,旧一代结果直接作废。
                guard requestID == contextRequestID else { return }
                localBranches = branches
                remoteTrackingBranches = remote
                var didResolve = false
                if baseRef == nil {
                    baseRef = defaultBranch ?? current ?? branches.first
                    didResolve = true
                }
                if headRef == nil {
                    headRef = current ?? branches.first
                    didResolve = true
                }
                // 上下文已就绪仍解析不出比较侧:空仓库(无任何分支)。
                if baseRef == nil || headRef == nil {
                    entries = []
                    divergence = nil
                    errorMessage = "仓库暂无分支，无法比较"
                    isLoading = false
                    hasLoadedInitialData = true
                    return
                }
                // 只在首次补全比较侧时触发加载;刷新场景由调用方自己 reloadDiff。
                if didResolve {
                    reloadDiff()
                }
            }
        }
    }

    private func reloadDiff() {
        loadTask?.cancel()
        guard let base = baseRef, let head = headRef else {
            // 分支上下文还没就绪(空仓库等):保持加载态,context 解析后会再次触发。
            isLoading = true
            return
        }
        isLoading = true
        errorMessage = nil
        // 与 loadBranchContext 同一代际号模式:isCancelled 检查与 MainActor.run
        // 落笔之间隔着挂起,快速连续切 base/head 时旧任务可能晚于新任务落笔。
        diffRequestID += 1
        let requestID = diffRequestID
        let path = payload.localPath
        let service = gitService
        loadTask = Task {
            let diffEntries = await service.diffBranches(base: base, head: head, in: path)
            let divergenceResult = await service.divergence(base: base, head: head, in: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard requestID == diffRequestID else { return }
                entries = diffEntries
                divergence = divergenceResult
                isLoading = false
                hasLoadedInitialData = true
            }
        }
    }

    private func swapRefs() {
        guard let base = baseRef, let head = headRef else { return }
        baseRef = head
        headRef = base
        reloadDiff()
    }
}
