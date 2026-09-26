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
    /// 分支上下文与 diff 的共享加载器(含代际防过期写回),视图只消费加载结果。
    @StateObject private var context: RepositoryWindowContext

    init(payload: BranchCompareWindowPayload, gitService: GitServicing) {
        self.payload = payload
        self.gitService = gitService
        _context = StateObject(wrappedValue: RepositoryWindowContext(gitService: gitService))
    }

    @State private var baseRef: String?
    @State private var headRef: String?
    @State private var localBranches: [String] = []
    @State private var remoteTrackingBranches: [String] = []
    @State private var entries: [GitDiffEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var divergence: GitRefDivergence?
    /// 首次加载是否已完成;跳过刚打开时的 becomeKey 重叠(与 Diff/提交记录窗口同一模式)。
    @State private var hasLoadedInitialData = false
    @State private var showingBasePicker = false
    @State private var showingHeadPicker = false
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中加载
    /// 不得再把结果写进新仓库的状态(与 DiffWindowView 的 payloadGeneration 同模式)。
    @State private var payloadGeneration = 0

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
            context.cancelAll()
        }
        .onChange(of: payload) { _, _ in
            // WindowGroup(for:) 复用同一窗口更换 payload 时 .task/onAppear 不会重跑:
            // 重置自持状态并按新参数重新加载,避免显示旧仓库的比较结果。
            // 先作废旧代际:旧仓库在途加载的写回会在代际比对处被丢弃。
            payloadGeneration += 1
            baseRef = payload.base
            headRef = payload.head
            entries = []
            divergence = nil
            errorMessage = nil
            isLoading = true
            hasLoadedInitialData = false
            loadBranchContext()
            reloadDiff()
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
    /// 并发取数与代际防过期写回收进 RepositoryWindowContext,这里只消费快照。
    private func loadBranchContext() {
        let generation = payloadGeneration
        context.loadBranchContext(
            directory: payload.localPath,
            includeMetadata: false
        ) { [self] snapshot in
            // payload 已更换(复用窗口换仓库)时旧仓库快照不得落笔。
            guard generation == payloadGeneration else { return }
            localBranches = snapshot.branches
            remoteTrackingBranches = snapshot.remoteTrackingBranches
            var didResolve = false
            if baseRef == nil {
                baseRef = snapshot.defaultBranch ?? snapshot.currentBranch ?? snapshot.branches.first
                didResolve = true
            }
            if headRef == nil {
                headRef = snapshot.currentBranch ?? snapshot.branches.first
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

    private func reloadDiff() {
        guard let base = baseRef, let head = headRef else {
            // 分支上下文还没就绪(空仓库等):保持加载态,context 解析后会再次触发。
            // 早退同样作废在途 diff 写回,窄窗口内旧任务的迟到落笔被代际拦下。
            context.invalidateDiffLoads()
            isLoading = true
            return
        }
        isLoading = true
        errorMessage = nil
        let generation = payloadGeneration
        context.loadCompareDiff(directory: payload.localPath, base: base, head: head) { [self] outcome in
            // payload 已更换(复用窗口换仓库)时旧仓库结果不得落笔。
            guard generation == payloadGeneration else { return }
            switch outcome {
            case .success(let diffEntries, let divergenceResult):
                entries = diffEntries
                divergence = divergenceResult
                isLoading = false
                hasLoadedInitialData = true
            case .failure(let message):
                // 查询失败与「两侧内容完全一致」是两回事:展示错误态而非空态。
                errorMessage = message
                isLoading = false
            case .cancelled:
                break
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
