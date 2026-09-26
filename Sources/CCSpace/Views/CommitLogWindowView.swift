import AppKit
import SwiftUI

/// 提交记录独立窗口的打开参数(与 DiffWindowPayload 同一套模式)。
/// 相等 payload 复用已打开窗口,不同仓库各开一窗。
struct CommitLogWindowPayload: Codable, Hashable {
    let repositoryName: String
    let localPath: String
}

/// 提交记录窗口:浏览任意分支(本地 + 远端跟踪)的历史。
///
/// 以普通窗口(非模态)呈现,与 Diff 窗口同级:标题栏分支 pill 点击弹出分支选择器 +
/// 搜索 + 仅看未推送 + 分页加载;行点击展开完整提交详情,右键/更多菜单支持基于提交建分支、
/// 浏览器打开提交页、打开该提交的 Diff 窗口。加载与操作状态由本窗口自持,与主窗口解耦。
struct CommitLogWindowView: View {
    let payload: CommitLogWindowPayload
    let gitService: GitServicing
    /// 写操作(基于提交建分支)的唯一入口:协调器内部持 per-path 锁与后台 pull/push 互斥。
    let syncCoordinator: SyncCoordinator
    /// 分支上下文与提交列表的共享加载器(含代际防过期写回),视图只消费加载结果。
    @StateObject private var context: RepositoryWindowContext

    init(
        payload: CommitLogWindowPayload,
        gitService: GitServicing,
        syncCoordinator: SyncCoordinator
    ) {
        self.payload = payload
        self.gitService = gitService
        self.syncCoordinator = syncCoordinator
        _context = StateObject(wrappedValue: RepositoryWindowContext(gitService: gitService))
    }

    @State private var selectedBranch: String?
    @State private var currentBranch: String?
    @State private var branchNames: [String] = []
    @State private var remoteTrackingBranches: [String] = []
    @State private var branchMetadata: [String: GitBranchMetadata] = [:]
    @State private var showingBranchPicker = false
    @State private var commits: [GitCommitEntry] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isUnpushedOnly = false
    @State private var limit = Self.pageSize
    @State private var hasMore = false
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中加载
    /// 不得再把结果写进新仓库的状态(与 DiffWindowView 的 payloadGeneration 同模式)。
    @State private var payloadGeneration = 0
    /// 首次加载是否已完成;用于跳过窗口刚打开时的 becomeKey 通知,避免重复加载
    /// (与 DiffWindowView 同一套模式:后台打开的窗口聚焦事件不可靠,首载由 task 驱动)。
    @State private var hasLoadedInitialData = false
    /// 展开详情的提交 id 集合(支持全部展开/折叠)与详情缓存;详情按需 `git show -s` 拉取。
    @State private var expandedIDs: Set<String> = []
    @State private var commitDetails: [String: GitCommitDetail] = [:]
    @State private var detailLoadingIDs: Set<String> = []
    @State private var detailFailedIDs: Set<String> = []
    /// "基于此提交创建分支"流程。
    @State private var createBranchCandidate: GitCommitEntry?
    @State private var newBranchName = ""
    @State private var isCreatingBranch = false
    /// 一次性提示/错误条(建分支失败、浏览器打开失败等),几秒后自动消失。
    @State private var noticeMessage: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var createBranchTask: Task<Void, Never>?
    /// 单行展开的详情任务句柄(按提交 id 归档):窗口关闭时纳入 cancelAllTasks 一并取消。
    @State private var detailTasks: [String: Task<Void, Never>] = [:]
    /// "全部展开"的限流详情加载任务句柄。
    @State private var expandAllTask: Task<Void, Never>?
    /// 当前"全部展开"批次覆盖的提交 id,取消时用于同步清加载标记。
    @State private var expandAllBatchIDs: Set<String> = []
    /// 批次令牌:每次启动新批次自增,批次回写点比对令牌,过期批次只认领标记不写状态。
    @State private var expandAllBatchToken = 0
    /// 已被取消/取代的批次 id 集合。git show 对取消不协作(进程返回后才生效),
    /// 旧批次的迟到写回会破坏新批次的加载标记,回写前先在此认领跳过。
    @State private var supersededDetailIDs: Set<String> = []
    @Environment(\.openWindow) private var openWindow

    private static let pageSize = 20
    /// 全部展开时详情加载的最大并发数(与 WorkplaceBranchLoader.maxConcurrentSnapshotLoads 同一量级)。
    private static let maxConcurrentDetailLoads = 8

    private var presentationState: CommitLogPresentationState {
        CommitLogPresentationState(
            commits: commits,
            searchText: searchText,
            scope: isUnpushedOnly ? .unpushedOnly : .all,
            hasUpstream: selectedHasUpstream,
            isRemoteTrackingRef: selectedIsRemoteTrackingRef
        )
    }

    /// 当前浏览分支是否有上游:元数据里查;HEAD 视图按当前分支判断。
    private var selectedHasUpstream: Bool {
        let branch = selectedBranch ?? currentBranch
        guard let branch else { return false }
        return branchMetadata[branch]?.hasUpstream ?? false
    }

    /// 当前浏览的是否为远端跟踪引用(origin/x):"仅看未推送"的提示按此归因,
    /// 不能对远端跟踪分支说"当前分支未关联远端"。
    private var selectedIsRemoteTrackingRef: Bool {
        guard let branch = selectedBranch else { return false }
        return remoteTrackingBranches.contains(branch)
    }

    /// 标题栏展示的分支名。
    private var branchLabel: String {
        selectedBranch ?? currentBranch ?? "HEAD"
    }

    var body: some View {
        // presentationState 每次访问都全量重过滤:body 顶部取一次局部值沿渲染路径复用,
        // 避免控制行/列表/分隔线判断各自触发一遍过滤。
        let state = presentationState
        return VStack(alignment: .leading, spacing: 0) {
            if let noticeMessage {
                Text(noticeMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .help(noticeMessage)
            }
            controls(state)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content(state)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 540)
        .navigationTitle(payload.repositoryName)
        .navigationSubtitle("提交记录")
        .toolbar {
            // 分支 pill 与展开/折叠拆成两颗胶囊:靠 ToolbarSpacer(.fixed) 分隔
            // (分支比较窗口同款);普通按钮直接一步切换,不带 Menu 下拉箭头。
            ToolbarItem(placement: .primaryAction) {
                branchPillButton
                    .padding(.leading, 6)
                    .padding(.trailing, 6)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        applyExpandAll(expand: allExpanded(state) == false, state: state)
                    }
                } label: {
                    Image(systemName: allExpanded(state) ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .disabled(commits.isEmpty)
                .ccspaceQuickHelp(allExpanded(state) ? "全部折叠" : "全部展开")
            }
        }
        .task {
            reload()
        }
        .onChange(of: payload) { _, _ in
            // WindowGroup(for:) 复用同一窗口更换 payload 时 .task 不会重跑:
            // 重置自持状态并按新参数重新加载,避免把旧仓库的提交列表展示进新仓库窗口。
            // 「基于提交建分支」等写动作据此不会指向旧仓库路径:弹窗输入与候选提交
            // 先行作废,在途加载的写回由代际比对拦下。
            payloadGeneration += 1
            cancelAllTasks()
            selectedBranch = nil
            currentBranch = nil
            branchNames = []
            remoteTrackingBranches = []
            branchMetadata = [:]
            commits = []
            isLoading = true
            isLoadingMore = false
            errorMessage = nil
            searchText = ""
            isUnpushedOnly = false
            limit = Self.pageSize
            hasMore = false
            hasLoadedInitialData = false
            expandedIDs = []
            commitDetails = [:]
            detailLoadingIDs = []
            detailFailedIDs = []
            createBranchCandidate = nil
            newBranchName = ""
            isCreatingBranch = false
            noticeMessage = nil
            reload()
        }
        .onWindowBecomeKey {
            // 相等 payload 的 openWindow 只聚焦不重建内容:聚焦时刷新保证数据最新;
            // 首次打开的 becomeKey 与 .task 首载重叠,由 hasLoadedInitialData 跳过。
            guard hasLoadedInitialData else { return }
            reload()
        }
        .onDisappear {
            cancelAllTasks()
        }
        .alert(
            createBranchTitle,
            isPresented: createBranchBinding
        ) {
            TextField("新分支名称", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
            Button("创建并切换") {
                submitCreateBranch()
            }
            .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingBranch)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将基于 \(createBranchCandidate?.shortHash ?? "") 创建并切换到新分支，工作区如有未提交改动可能被 git 拒绝。")
        }
    }

    /// 标题栏分支 pill:与仓库行同款样式,兼作分支选择器入口。
    private var branchPillButton: some View {
        Button {
            showingBranchPicker = true
        } label: {
            RepositoryBranchPill(title: branchLabel, showsIcon: false)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .ccspaceQuickHelp("点击切换要查看的分支")
        .ccspacePopover(isPresented: $showingBranchPicker, arrowEdge: .bottom) {
            // 锚点在系统标题栏上:弹窗内容会继承锚点环境,标题栏的大字号会让整个
            // 分支列表比仓库行版本大一圈,这里显式钉回常规控件尺寸与正文字号。
            BranchListPopoverView(
                currentBranch: selectedBranch ?? currentBranch,
                localBranches: branchNames,
                remoteTrackingBranches: remoteTrackingBranches,
                pickHint: "点击查看该分支提交记录",
                onCompare: { ref in
                    showingBranchPicker = false
                    guard ref != selectedBranch else { return }
                    selectedBranch = ref
                    // 换分支后"仅看未推送"的可用性可能变化(新分支未必有上游),
                    // 留在勾选态会得到误导性的空列表,直接重置。
                    isUnpushedOnly = false
                    limit = Self.pageSize
                    reloadCommits(resetting: true, showLoading: true)
                }
            )
            .environment(\.controlSize, .regular)
            .font(.body)
        }
    }

    private var createBranchTitle: String {
        "基于提交 \(createBranchCandidate?.shortHash ?? "") 新建分支"
    }

    private var createBranchBinding: Binding<Bool> {
        Binding(
            get: { createBranchCandidate != nil },
            set: { isPresented in
                if isPresented == false {
                    createBranchCandidate = nil
                    newBranchName = ""
                    isCreatingBranch = false
                }
            }
        )
    }

    // MARK: - 控制行

    private func controls(_ state: CommitLogPresentationState) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索提交、作者或 ID", text: $searchText)
                    .textFieldStyle(.plain)
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Toggle("仅看未推送", isOn: $isUnpushedOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
                .fixedSize()
                .disabled(!state.canFilterUnpushed)
                .help(state.unpushedToggleHelp)

            Spacer()
            Text(state.countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            // 刷新收进搜索行尾:标题栏让给仓库名与分支 pill;窗口聚焦也会自动刷新。
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("刷新")
            .accessibilityLabel("刷新")
        }
        .onChange(of: isUnpushedOnly) { _, _ in
            // 切换筛选只重置分页,保留搜索词。
            limit = Self.pageSize
            reloadCommits(resetting: true, showLoading: true)
        }
    }

    // MARK: - 列表区

    @ViewBuilder
    private func content(_ state: CommitLogPresentationState) -> some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text("加载提交记录失败")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("重试") { reload() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.filteredCommits.isEmpty {
            VStack(spacing: 4) {
                Spacer()
                Text(state.emptyTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if state.emptySubtitle.isEmpty == false {
                    Text(state.emptySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 分隔线判断改用下标:此前每行取一次 filteredCommits.last,整列表 O(N²)。
            let visibleCommits = state.filteredCommits
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleCommits.enumerated()), id: \.element.id) { index, commit in
                        CommitLogRowView(
                            commit: commit,
                            isExpanded: expandedIDs.contains(commit.id),
                            detail: commitDetails[commit.id],
                            isLoadingDetail: detailLoadingIDs.contains(commit.id),
                            detailLoadFailed: detailFailedIDs.contains(commit.id),
                            onToggleExpand: { toggleExpand(for: commit) },
                            onShowDiff: { presentCommitDiff(for: commit) },
                            onCreateBranch: { startCreateBranch(from: commit) }
                        )
                        if index < visibleCommits.count - 1 {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                    if hasMore {
                        // 固定高度:按钮与加载指示切换、末页消失都不改变页脚占位,列表不抖动。
                        ZStack {
                            Button("加载更多") { loadMore() }
                                .controlSize(.small)
                                .opacity(isLoadingMore ? 0 : 1)
                                .disabled(isLoadingMore)
                            if isLoadingMore {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("加载中…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .padding(.vertical, 8)
                        .animation(.easeInOut(duration: 0.15), value: isLoadingMore)
                    }
                }
            }
        }
    }

    // MARK: - 加载

    private func cancelAllTasks() {
        // 共享加载器(分支上下文/提交列表)的在途任务一并取消,避免迟到写回。
        context.cancelAll()
        // 详情任务与提示任务同样纳入取消:此前遗漏,窗口关闭后 git show 仍在后台跑。
        cancelExpandAllBatch()
        for task in detailTasks.values {
            task.cancel()
        }
        detailTasks.removeAll()
        noticeTask?.cancel()
        noticeTask = nil
        // 建分支会写 HEAD,窗口关闭后必须一并取消,否则仍会跑完并 reload。
        createBranchTask?.cancel()
        createBranchTask = nil
    }

    private func reload() {
        loadBranchContext()
        limit = Self.pageSize
        reloadCommits(resetting: true, showLoading: true)
    }

    /// 分支名单/远端跟踪分支/元数据/当前分支:供标题栏分支选择器与"仅看未推送"可用性判断。
    /// 并发取数与代际防过期写回收进 RepositoryWindowContext,这里只消费快照。
    private func loadBranchContext() {
        let generation = payloadGeneration
        context.loadBranchContext(
            directory: payload.localPath,
            includeMetadata: true
        ) { [self] snapshot in
            // payload 已更换(复用窗口换仓库)时旧仓库快照不得落笔。
            guard generation == payloadGeneration else { return }
            branchNames = snapshot.branches
            remoteTrackingBranches = snapshot.remoteTrackingBranches
            branchMetadata = snapshot.metadata ?? [:]
            currentBranch = snapshot.currentBranch
        }
    }

    private func reloadCommits(resetting: Bool, showLoading: Bool) {
        let generation = payloadGeneration
        let path = payload.localPath
        if resetting {
            if showLoading {
                isLoading = true
            }
            commits = []
            errorMessage = nil
            hasMore = false
        } else {
            isLoadingMore = true
        }
        let unpushedOnly = isUnpushedOnly
        let rev = selectedBranch
        let currentLimit = limit
        context.loadCommits(
            directory: path,
            limit: currentLimit,
            rev: rev,
            unpushedOnly: unpushedOnly
        ) { [self] outcome in
            // payload 已更换(复用窗口换仓库)时旧仓库结果不得落笔。
            guard generation == payloadGeneration else { return }
            switch outcome {
            case .directoryMissing(let missingPath):
                errorMessage = "本地目录不存在：\(missingPath)"
                isLoading = false
                isLoadingMore = false
                hasLoadedInitialData = true
            case .success(let fetched, let hasMoreResult):
                hasMore = hasMoreResult
                commits = hasMore ? Array(fetched.prefix(currentLimit)) : fetched
                isLoading = false
                isLoadingMore = false
                hasLoadedInitialData = true
            }
        }
    }

    private func loadMore() {
        limit += Self.pageSize
        // resetting=false:保留已加载列表,只追加;清空重拉会造成列表闪空。
        reloadCommits(resetting: false, showLoading: false)
    }

    // MARK: - 详情展开

    private func toggleExpand(for commit: GitCommitEntry) {
        if expandedIDs.contains(commit.id) {
            expandedIDs.remove(commit.id)
            return
        }
        expandedIDs.insert(commit.id)
        ensureDetail(for: commit)
    }

    /// 当前可见提交是否已全部展开(与 Diff 查看器"全部展开/折叠"按钮同语义)。
    private func allExpanded(_ state: CommitLogPresentationState) -> Bool {
        let visible = state.filteredCommits
        guard visible.isEmpty == false else { return false }
        return visible.allSatisfy { expandedIDs.contains($0.id) }
    }

    /// 全部展开/折叠。展开时详情经 ConcurrencyUtilities.runLimitedTasks 限并发拉取:
    /// 此前每个可见提交各起一个无句柄 Task,长列表会同时压上几十个 git show 进程,
    /// 且窗口关闭时无法取消。
    /// 取消当前"全部展开"批次并同步清理其加载标记。
    /// gitService.commitDetail 对取消不协作(要等 git 进程返回),旧批次的标记
    /// 会滞留到最慢进程退出——期间再次展开会因 pending 全被标记排除而提前返回,
    /// 造成"已展开、非加载、无详情"的死态。取消即认领:标记立刻交还,
    /// 旧批次的迟到写回经 supersededDetailIDs 拦下,不再破坏新批次。
    private func cancelExpandAllBatch() {
        expandAllTask?.cancel()
        expandAllTask = nil
        // 令牌自增:即使走的是"再次展开"路径(本函数在置入新标记前调用),
        // 旧批次的回写也会因令牌过期被拦下。
        expandAllBatchToken += 1
        guard expandAllBatchIDs.isEmpty == false else { return }
        for id in expandAllBatchIDs {
            detailLoadingIDs.remove(id)
            supersededDetailIDs.insert(id)
        }
        expandAllBatchIDs.removeAll()
    }

    private func applyExpandAll(expand: Bool, state: CommitLogPresentationState) {
        guard expand else {
            cancelExpandAllBatch()
            expandedIDs.removeAll()
            return
        }
        let visible = state.filteredCommits
        guard visible.isEmpty == false else { return }
        for commit in visible {
            expandedIDs.insert(commit.id)
        }
        let pending = visible.filter {
            commitDetails[$0.id] == nil && detailLoadingIDs.contains($0.id) == false
        }
        guard pending.isEmpty == false else { return }
        cancelExpandAllBatch()
        for commit in pending {
            detailLoadingIDs.insert(commit.id)
            detailFailedIDs.remove(commit.id)
            // 新批次认领自己的 id:清掉任何来源的滞留 superseded 标记,
            // 防止陈旧标记影响后续批次的收尾统计。
            supersededDetailIDs.remove(commit.id)
        }
        let path = payload.localPath
        let gitService = gitService
        expandAllBatchIDs = Set(pending.map(\.id))
        let batchIDs = expandAllBatchIDs
        let batchToken = expandAllBatchToken
        expandAllTask = Task {
            // 结果经 MainActor.run 直接写回状态集合,返回值本身无需消费。
            _ = await ConcurrencyUtilities.runLimitedTasks(
                pending,
                maxConcurrentTasks: Self.maxConcurrentDetailLoads
            ) { commit in
                guard !Task.isCancelled else { return }
                let detail = await gitService.commitDetail(hash: commit.hash, in: path)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // 取代判定只看令牌:旧批次(令牌过期)的回写必被拦下。
                    // 不能按 supersededDetailIDs 逐条拦截——旧批次的标记要等其
                    // 最慢进程退出才被认领,期间**新批次**对同一提交 id 的合法
                    // 回写会被滞留标记误杀,重新造成"已展开、非加载、无详情"死空白。
                    if batchToken != expandAllBatchToken {
                        supersededDetailIDs.remove(commit.id)
                        return
                    }
                    detailLoadingIDs.remove(commit.id)
                    if let detail {
                        commitDetails[commit.id] = detail
                    } else {
                        detailFailedIDs.insert(commit.id)
                    }
                }
            }
            // 取消路径(折叠/再次展开/关窗)下子任务直接 return,不写回状态:
            // 这里统一清掉本批置入的加载标记,否则被取消的提交永久滞留
            // detailLoadingIDs,后续单行展开被守卫跳过、UI 卡"加载中"死态。
            // 已被 cancelExpandAllBatch 认领过的批次此处只清 superseded,remove 幂等。
            await MainActor.run {
                if batchToken == expandAllBatchToken {
                    for commit in pending {
                        detailLoadingIDs.remove(commit.id)
                        supersededDetailIDs.remove(commit.id)
                    }
                    expandAllBatchIDs = []
                } else {
                    for id in batchIDs {
                        supersededDetailIDs.remove(id)
                    }
                }
            }
        }
    }

    /// 按需拉取提交详情并缓存;同一提交只发一次,加载中的不重复触发。
    /// 任务句柄按提交 id 归档,纳入 cancelAllTasks 统一取消。
    private func ensureDetail(for commit: GitCommitEntry) {
        let id = commit.id
        guard commitDetails[id] == nil, detailLoadingIDs.contains(id) == false else { return }
        detailLoadingIDs.insert(id)
        detailFailedIDs.remove(id)
        detailTasks[id] = Task {
            await loadDetail(for: commit)
            await MainActor.run {
                detailTasks[id] = nil
            }
        }
    }

    /// 拉取单条提交详情并回写缓存/加载/失败集合(单行展开与全部展开共用)。
    private func loadDetail(for commit: GitCommitEntry) async {
        let id = commit.id
        let path = payload.localPath
        let hash = commit.hash
        let gitService = gitService
        let detail = await gitService.commitDetail(hash: hash, in: path)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            detailLoadingIDs.remove(id)
            if let detail {
                commitDetails[id] = detail
            } else {
                detailFailedIDs.insert(id)
            }
        }
    }

    // MARK: - 操作

    private func presentCommitDiff(for commit: GitCommitEntry) {
        openWindow(value: DiffWindowPayload(
            repositoryName: payload.repositoryName,
            localPath: payload.localPath,
            title: String(commit.subject.prefix(40)),
            source: .commit(hash: commit.hash)
        ))
    }

    private func startCreateBranch(from commit: GitCommitEntry) {
        newBranchName = ""
        createBranchCandidate = commit
    }

    private func submitCreateBranch() {
        let branch = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch.isEmpty == false, let commit = createBranchCandidate else { return }
        // 与 BranchSwitchPopoverView 的内联建分支同一套校验规则:空格/^/../等
        // 非法名在提交前拦下并提示,而不是把裸 git 报错甩给用户。
        if let validationProblem = BranchNameValidation.validate(branch) {
            showNotice(validationProblem, isError: true)
            return
        }
        isCreatingBranch = true
        let path = payload.localPath
        let coordinator = syncCoordinator
        createBranchTask?.cancel()
        let generation = payloadGeneration
        createBranchTask = Task {
            do {
                try await coordinator.createBranchFromRevision(branch, fromRev: commit.hash, in: path)
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                await MainActor.run {
                    createBranchCandidate = nil
                    newBranchName = ""
                    isCreatingBranch = false
                    // 建分支即切换:HEAD 视图与分支列表都变了,整体刷新。
                    selectedBranch = nil
                    reload()
                    showNotice("已基于 \(commit.shortHash) 创建并切换到 \(branch)", isError: false)
                }
            } catch {
                // payload 已更换时旧仓库的建分支结果不得写进新仓库窗口。
                guard !Task.isCancelled, generation == payloadGeneration else { return }
                await MainActor.run {
                    isCreatingBranch = false
                    showNotice("创建分支失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func showNotice(_ message: String, isError: Bool) {
        noticeTask?.cancel()
        noticeMessage = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 8 : 4))
            guard !Task.isCancelled else { return }
            await MainActor.run { noticeMessage = nil }
        }
    }
}

/// 提交行:标题 + hash/统计/作者/时间 + 行内操作(复制 commit ID/基于此提交建分支/
/// 查看改动);点击展开完整详情。
struct CommitLogRowView: View {
    let commit: GitCommitEntry
    let isExpanded: Bool
    let detail: GitCommitDetail?
    let isLoadingDetail: Bool
    let detailLoadFailed: Bool
    let onToggleExpand: () -> Void
    let onShowDiff: () -> Void
    let onCreateBranch: () -> Void

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(commit.shortHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                }

                if commit.hasStats {
                    HStack(spacing: 3) {
                        if let insertions = commit.insertions, insertions > 0 {
                            Text("+\(insertions)")
                                .foregroundStyle(.green)
                        }
                        if let deletions = commit.deletions, deletions > 0 {
                            Text("-\(deletions)")
                                .foregroundStyle(.red)
                        }
                        if let files = commit.filesChanged {
                            Text("· \(files) 文件")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.monospaced())
                }

                Text(commit.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // 窄窗口下压缩顺序里保作者不被截掉:优先让位给作者,时间/按钮本身定宽。
                    .layoutPriority(1)
                Spacer()
                Text(commit.date.relativeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    copyFullHash()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .ccspaceQuickHelp(copied ? "已复制" : "复制完整 commit ID", providesLabel: true)
                Button(action: onCreateBranch) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .ccspaceQuickHelp("基于此提交创建分支", providesLabel: true)
                Button(action: onShowDiff) {
                    Label("查看改动", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isExpanded {
                detailView
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onToggleExpand()
        }
        .animation(.easeInOut(duration: 0.2), value: copied)
        .onDisappear {
            resetTask?.cancel()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLoadingDetail {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载提交详情…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if detailLoadFailed {
                Text("加载提交详情失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let detail {
                Text(detail.fullMessage)
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(detail.hash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if detail.authorEmail.isEmpty == false {
                        Text("· \(detail.authorName) <\(detail.authorEmail)>")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = detail.date {
                        Text("· \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyFullHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
