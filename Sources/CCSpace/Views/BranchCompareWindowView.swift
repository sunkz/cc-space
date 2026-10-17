import SwiftUI

/// base/head 为 nil 时由窗口在加载分支上下文后兜底解析(base=默认分支,head=当前分支)。
struct BranchCompareWindowPayload: Codable, Hashable {
    let repositoryName: String
    let localPath: String
    var base: String? = nil
    var head: String? = nil
}

struct BranchCompareWindowView: View {
    let payload: BranchCompareWindowPayload
    let gitService: GitServicing
    /// 分支上下文与 diff 的共享加载器(含代际防过期写回)。
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

    private var source: RepositoryWindowContext.DiffSource {
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
            // from/to 分支 chip 与互换按钮收进同一个 ToolbarItem:分成三个 item 时系统会在 item 间插入
            // 较宽默认间距,合成一个后由 spacing 精确控制贴合感;标题/副标题由内层 DiffViewerView 提供。
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
            // 先作废旧代际,旧仓库在途加载的写回才会在代际比对处被丢弃。
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

    /// 不设宽度上限:pill 随分支名长度自适应展示全名。
    private func refChip(ref: String?, fallback: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RepositoryBranchPill(title: ref ?? fallback, showsIcon: false)
        }
        .buttonStyle(.plain)
        .ccspaceQuickHelp(ref ?? fallback)
    }

    /// 选中回调上抛 git 可用引用(本地裸名 / origin/ 跟踪名),列表展示的是去前缀的裸名。
    /// 锚点在系统标题栏上:弹窗内容会继承锚点环境的大字号,须显式钉回常规尺寸(与提交记录窗口同一处理)。
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

    /// 「展示所有行」新侧全文:与 Diff 窗口同源(head 是否当前分支决定读磁盘还是 blob),
    /// 读盘/解码重活由 context 内部包进 `Task.detached`,不随调用方留在主线程。
    private var fullFileContentProvider: @Sendable (GitDiffEntry) async -> String? {
        let localPath = payload.localPath
        let diffSource = source
        let context = _context.wrappedValue
        return { entry in
            await context.fullFileContent(entry: entry, directory: localPath, source: diffSource)
        }
    }

    // MARK: - 加载

    /// 供两侧选择器的分支名单;顺带兜底解析未提供的初始 base/head。
    /// 并发取数与代际防过期写回收进 RepositoryWindowContext,这里只消费快照。
    private func loadBranchContext() {
        let generation = payloadGeneration
        context.loadBranchContext(
            directory: payload.localPath,
            includeMetadata: false
        ) { [self] snapshot in
            // payload 已更换(复用窗口换仓库)时旧仓库快照不得落笔。
            guard generation == payloadGeneration else { return }
            // nil = 该项读取失败:保留上一轮的名单,不能折算成"这个仓库没有分支"。
            if let branches = snapshot.branches { localBranches = branches }
            if let remote = snapshot.remoteTrackingBranches { remoteTrackingBranches = remote }
            let branchList = snapshot.branches ?? localBranches
            var didResolve = false
            if baseRef == nil {
                baseRef = snapshot.defaultBranch ?? snapshot.currentBranch ?? branchList.first
                didResolve = true
            }
            if headRef == nil {
                headRef = snapshot.currentBranch ?? branchList.first
                didResolve = true
            }
            // 上下文已就绪仍解析不出比较侧:空仓库(无任何分支)。
            if baseRef == nil || headRef == nil {
                entries = []
                divergence = nil
                // 区分两种"没有分支可选":名单读取失败 ≠ 仓库真的是空的。
                errorMessage = snapshot.branches == nil
                    ? "分支信息读取失败，请稍后重试"
                    : "仓库暂无分支，无法比较"
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
        // 换分支/互换方向与重新加载期间,上一次比较的分歧数一律作废:留着会把旧数字和新分支名
        // 拼在一起,加载失败时更是挂着上次的结果不走。
        divergence = nil
        guard let base = baseRef, let head = headRef else {
            // 分支上下文还没就绪(空仓库等):保持加载态,context 解析后会再次触发;
            // 早退同样作废在途 diff 写回,窄窗口内旧任务的迟到落笔被代际拦下。
            context.invalidateDiffLoads()
            isLoading = true
            return
        }
        isLoading = true
        errorMessage = nil
        let generation = payloadGeneration
        context.loadCompareDiff(directory: payload.localPath, base: base, head: head) { [self] outcome in
            guard generation == payloadGeneration else { return }
            switch outcome {
            case .success(let diffEntries, let divergenceResult):
                entries = diffEntries
                divergence = divergenceResult
                isLoading = false
                hasLoadedInitialData = true
            case .failure(let message):
                // 查询失败与「两侧内容完全一致」是两回事:展示错误态而非空态;
                // 首载流程失败也算结束,否则聚焦自动刷新从此停摆。
                errorMessage = message
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
