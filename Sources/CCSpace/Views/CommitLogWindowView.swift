import AppKit
import SwiftUI

/// 提交记录独立窗口的打开参数(与 DiffWindowPayload 同一套模式)。
/// 相等 payload 复用已打开窗口,不同仓库各开一窗。
struct CommitLogWindowPayload: Codable, Hashable {
    let repositoryName: String
    let localPath: String
}

/// 提交记录独立窗口:浏览任意分支(本地 + 远端跟踪)的历史,以普通窗口(非模态)呈现。
/// 行点击展开详情,右键/更多菜单支持基于提交建分支、打开提交页与 Diff;加载与操作状态由本窗口自持。
struct CommitLogWindowView: View {
    let payload: CommitLogWindowPayload
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
    /// git 侧已消耗的偏移量(`--skip` 游标),与 `commits.count` 不是一回事:顶端新进提交时翻页去重会吞掉 k 条,
    /// 用展示数当游标会少让 k 条,那 k 条历史既不在已展示页也永远翻不到(静默丢数据);游标按 git 返回行数推进。
    @State private var fetchedRowCount = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isUnpushedOnly = false
    @State private var hasMore = false
    /// 程序性重置"仅看未推送"(换 payload / 换分支)时置真,由 onChange 消费一次即复位:
    /// 程序重置由各路径自己的 reload 统一刷新,避免重复触发整屏加载。
    @State private var programmaticUnpushedReset = false
    /// payload 代际号:WindowGroup 复用同一窗口更换 payload 时,旧仓库的进行中加载不得再写进新仓库状态。
    @State private var payloadGeneration = 0
    /// 首次加载是否已完成;用于跳过窗口刚打开时的 becomeKey 通知,避免重复加载(首载由 task 驱动)。
    @State private var hasLoadedInitialData = false
    /// 展开详情的提交 id 集合(支持全部展开/折叠)与详情缓存;详情按需 `git show -s` 拉取。
    @State private var expandedIDs: Set<String> = []
    @State private var commitDetails: [String: GitCommitDetail] = [:]
    @State private var detailLoadingIDs: Set<String> = []
    @State private var detailFailedIDs: Set<String> = []
    @State private var createBranchCandidate: GitCommitEntry?
    @State private var newBranchName = ""
    @State private var isCreatingBranch = false
    /// 一次性提示/错误条(建分支失败、浏览器打开失败等),几秒后自动消失。
    @State private var noticeMessage: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var createBranchTask: Task<Void, Never>?
    /// 单行展开的详情任务句柄(按提交 id 归档):窗口关闭时纳入 cancelAllTasks 一并取消。
    @State private var detailTasks: [String: Task<Void, Never>] = [:]
    @State private var expandAllTask: Task<Void, Never>?
    /// 搜索输入防抖:关键词过滤已下推到 git(每轮扫历史),逐键触发会排起连续查询,停手后才发一次。
    @State private var searchTask: Task<Void, Never>?
    /// 当前"全部展开"批次覆盖的提交 id,取消时用于同步清加载标记。
    @State private var expandAllBatchIDs: Set<String> = []
    /// 批次令牌:每次启动新批次自增,批次回写点比对令牌,过期批次只认领标记不写状态。
    @State private var expandAllBatchToken = 0
    @Environment(\.openWindow) private var openWindow

    private static let pageSize = 20
    /// 搜索防抖时长:关键词进 git 查询,每轮都要扫一遍历史。
    private static let searchDebounceNanoseconds: UInt64 = 250_000_000
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

    /// 当前浏览的是否为远端跟踪引用(origin/x):"仅看未推送"的提示按此归因。
    private var selectedIsRemoteTrackingRef: Bool {
        guard let branch = selectedBranch else { return false }
        return remoteTrackingBranches.contains(branch)
    }

    private var branchLabel: String {
        selectedBranch ?? currentBranch ?? "HEAD"
    }

    var body: some View {
        // presentationState 每次访问都全量重过滤:body 顶部取一次局部值沿渲染路径复用。
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
            // 分支 pill 与展开/折叠拆成两颗胶囊:靠 ToolbarSpacer(.fixed) 分隔(分支比较窗口同款)。
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
                .ccspaceQuickHelp(allExpanded(state) ? "全部折叠" : "全部展开", providesLabel: true)
            }
        }
        .task {
            reload()
        }
        .onChange(of: payload) { _, _ in
            // WindowGroup(for:) 复用同一窗口更换 payload 时 .task 不会重跑:重置自持状态并按新参数重载。
            // 建分支弹窗与候选提交先行作废,在途加载的写回由代际比对拦下。
            payloadGeneration += 1
            cancelAllTasks()
            selectedBranch = nil
            currentBranch = nil
            branchNames = []
            remoteTrackingBranches = []
            branchMetadata = [:]
            showingBranchPicker = false
            commits = []
            isLoading = true
            isLoadingMore = false
            errorMessage = nil
            searchText = ""
            resetUnpushedOnlyProgrammatically()
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
            // 相等 payload 的 openWindow 只聚焦不重建内容:聚焦时静默刷新保证数据最新。
            // 不得调 reload()(会打回首页并闪整屏加载态,翻历史时切出再切回浏览位置直接丢失):
            // 走 .reloadLoaded 按已加载条数整窗重取;首开的 becomeKey 与 .task 首载重叠,由 hasLoadedInitialData 跳过。
            guard hasLoadedInitialData else { return }
            guard isCreatingBranch == false else { return }
            loadBranchContext()
            reloadCommits(.reloadLoaded)
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
            // 弹窗内容继承标题栏锚点环境的大字号,显式钉回常规控件尺寸与正文字号。
            BranchListPopoverView(
                currentBranch: selectedBranch ?? currentBranch,
                localBranches: branchNames,
                remoteTrackingBranches: remoteTrackingBranches,
                pickHint: "点击查看该分支提交记录",
                onCompare: { ref in
                    showingBranchPicker = false
                    guard ref != selectedBranch else { return }
                    selectedBranch = ref
                    // 新分支未必有上游:留在勾选态会得到误导性的空列表,换分支直接重置。
                    resetUnpushedOnlyProgrammatically()
                    reloadCommits(.firstPageWithSpinner)
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
                TextField("搜索提交说明、作者或 ID", text: $searchText)
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
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
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
        .onChange(of: searchText) { _, _ in
            // 关键词进 git 查询,防抖避免一串击键排成一串历史扫描;清空同样走这条路回无过滤首页。
            scheduleSearchReload()
        }
        .onChange(of: isUnpushedOnly) { _, _ in
            // 程序性重置走各自路径的统一刷新,这里只响应用户切换。
            if programmaticUnpushedReset {
                programmaticUnpushedReset = false
                return
            }
            reloadCommits(.firstPageWithSpinner)
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
        } else if state.visibleCommits.isEmpty {
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
            // 分隔线判断用下标:每行取一次 visibleCommits.last 会让整列表 O(N²)。
            let visibleCommits = state.visibleCommits
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
        cancelExpandAllBatch()
        for task in detailTasks.values {
            task.cancel()
        }
        detailTasks.removeAll()
        noticeTask?.cancel()
        noticeTask = nil
        // 防抖中的搜索也要作废:否则窗口消失后计时器照样会把一轮 git log 打出去。
        searchTask?.cancel()
        searchTask = nil
        // 建分支会写 HEAD,窗口关闭后必须一并取消,否则仍会跑完并 reload。
        createBranchTask?.cancel()
        createBranchTask = nil
    }

    /// 程序性复位"仅看未推送":仅在勾选态时打分流标记——值未变化则 onChange 不触发,标记会悬留吞掉下次用户切换。
    private func resetUnpushedOnlyProgrammatically() {
        guard isUnpushedOnly else { return }
        programmaticUnpushedReset = true
        isUnpushedOnly = false
    }

    private func reload() {
        loadBranchContext()
        reloadCommits(.firstPageWithSpinner)
    }

    /// 分支名单/远端跟踪分支/元数据/当前分支:供标题栏分支选择器与"仅看未推送"可用性判断;取数与代际写回收进 RepositoryWindowContext。
    private func loadBranchContext() {
        let generation = payloadGeneration
        context.loadBranchContext(
            directory: payload.localPath,
            includeMetadata: true
        ) { [self] snapshot in
            // payload 已更换(复用窗口换仓库)时旧仓库快照不得落笔。
            guard generation == payloadGeneration else { return }
            // nil = 该项读取失败(超时/输出超限/进程起不来):保留上一轮结果,不把一次超时报成"没有分支"。
            if let branches = snapshot.branches { branchNames = branches }
            if let remote = snapshot.remoteTrackingBranches { remoteTrackingBranches = remote }
            if let metadata = snapshot.metadata { branchMetadata = metadata }
            currentBranch = snapshot.currentBranch
        }
    }

    /// 提交列表加载方式:分页游标即"已加载条数"(git 侧 `--skip` 偏移),各方式只是 skip/count 组合。
    private enum CommitLogLoadKind {
        /// 回到首页并整屏转圈(首载、换分支、换"仅看未推送"、手动刷新)。
        case firstPageWithSpinner
        /// 回到首页但先保留现有列表(关键词变化:新结果到达前不清空,避免整屏闪空)。
        case firstPageQuietly
        /// 按已加载条数整窗重取,保留浏览位置(窗口聚焦时的静默刷新)。
        case reloadLoaded
        /// 追加下一页("加载更多")。
        case nextPage
    }

    private func reloadCommits(_ kind: CommitLogLoadKind) {
        let generation = payloadGeneration
        let loadedCount = commits.count
        let pageSize: Int
        let skip: Int
        switch kind {
        case .firstPageWithSpinner, .firstPageQuietly:
            pageSize = Self.pageSize
            skip = 0
        case .reloadLoaded:
            // 整窗重取:条数不足一页时仍按一页取,避免空列表下退化成零条查询。
            pageSize = max(Self.pageSize, loadedCount)
            skip = 0
        case .nextPage:
            pageSize = Self.pageSize
            // 游标用 git 侧偏移,不用去重后的展示条数(见 fetchedRowCount 注释)。
            skip = fetchedRowCount
        }

        switch kind {
        case .firstPageWithSpinner:
            isLoading = true
            commits = []
            errorMessage = nil
            hasMore = false
        case .firstPageQuietly, .reloadLoaded, .nextPage:
            // 保留现有列表,只在搜索行/页脚转圈。
            isLoadingMore = true
        }

        let request = CommitLogPageRequest(
            directory: payload.localPath,
            searchText: searchText,
            skip: skip,
            count: pageSize,
            rev: selectedBranch,
            unpushedOnly: isUnpushedOnly
        )
        context.loadCommits(request: request) { [self] outcome in
            // payload 已更换(复用窗口换仓库)时旧仓库结果不得落笔。
            guard generation == payloadGeneration else { return }
            switch outcome {
            case .directoryMissing(let missingPath):
                errorMessage = "本地目录不存在：\(missingPath)"
                isLoading = false
                isLoadingMore = false
                hasLoadedInitialData = true
            case .success(let pageCommits, let more):
                hasMore = more
                // 游标按 git 实际返回的行数推进/重置,与去重后的展示条数解耦。
                if kind == .nextPage {
                    fetchedRowCount += pageCommits.count
                } else {
                    fetchedRowCount = pageCommits.count
                }
                if kind == .nextPage {
                    // 期间若有新提交落到分支顶端,下一页会重复带上已展示的头部提交:按哈希去重后再追加。
                    let shown = Set(commits.map(\.hash))
                    commits.append(contentsOf: pageCommits.filter { shown.contains($0.hash) == false })
                } else {
                    commits = pageCommits
                }
                // 静默刷新也要清错误:content 优先渲染错误页,不清则列表已更新、界面却永远停在错误。
                errorMessage = nil
                isLoading = false
                isLoadingMore = false
                hasLoadedInitialData = true
            }
        }
    }

    private func loadMore() {
        reloadCommits(.nextPage)
    }

    /// 关键词防抖:搜索已下推到 git,每轮都要扫一遍历史,停手后才发一次。
    private func scheduleSearchReload() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard Task.isCancelled == false else { return }
            reloadCommits(.firstPageQuietly)
        }
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

    /// 当前可见提交是否已全部展开。
    private func allExpanded(_ state: CommitLogPresentationState) -> Bool {
        let visible = state.visibleCommits
        guard visible.isEmpty == false else { return false }
        return visible.allSatisfy { expandedIDs.contains($0.id) }
    }

    /// 取消当前"全部展开"批次并同步清加载标记:git show 对取消不协作(要等进程返回),旧批次标记会滞留——
    /// 期间再次展开会因 pending 全被标记排除而提前返回,造成"已展开、无详情"死态;令牌自增拦下旧批次迟到写回。
    private func cancelExpandAllBatch() {
        expandAllTask?.cancel()
        expandAllTask = nil
        // 令牌自增:即使走的是"再次展开"路径(本函数在置入新标记前调用),
        // 旧批次的回写也会因令牌过期被拦下。
        expandAllBatchToken += 1
        guard expandAllBatchIDs.isEmpty == false else { return }
        for id in expandAllBatchIDs {
            detailLoadingIDs.remove(id)
        }
        expandAllBatchIDs.removeAll()
    }

    private func applyExpandAll(expand: Bool, state: CommitLogPresentationState) {
        guard expand else {
            cancelExpandAllBatch()
            expandedIDs.removeAll()
            return
        }
        let visible = state.visibleCommits
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
        }
        let path = payload.localPath
        let context = _context.wrappedValue
        expandAllBatchIDs = Set(pending.map(\.id))
        let batchToken = expandAllBatchToken
        expandAllTask = Task {
            _ = await ConcurrencyUtilities.runLimitedTasks(
                pending,
                maxConcurrentTasks: Self.maxConcurrentDetailLoads
            ) { commit in
                guard !Task.isCancelled else { return }
                let detail = await context.commitDetail(hash: commit.hash, directory: path)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // 令牌过期即旧批次,其迟到写回直接丢弃。
                    guard batchToken == expandAllBatchToken else { return }
                    detailLoadingIDs.remove(commit.id)
                    if let detail {
                        commitDetails[commit.id] = detail
                    } else {
                        detailFailedIDs.insert(commit.id)
                    }
                }
            }
            // 取消路径下子任务直接 return 不写回:这里统一清掉本批置入的加载标记,
            // 否则被取消的提交永久滞留 detailLoadingIDs,后续单行展开被守卫跳过、卡"加载中"死态。
            await MainActor.run {
                guard batchToken == expandAllBatchToken else { return }
                for commit in pending {
                    detailLoadingIDs.remove(commit.id)
                }
                expandAllBatchIDs = []
            }
        }
    }

    /// 按需拉取提交详情并缓存;同一提交只发一次,任务句柄按 id 归档纳入 cancelAllTasks 统一取消。
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

    private func loadDetail(for commit: GitCommitEntry) async {
        let id = commit.id
        let path = payload.localPath
        let hash = commit.hash
        let detail = await _context.wrappedValue.commitDetail(hash: hash, directory: path)
        // 取消同样要收口加载标记:直接 return 会让提交永久滞留,再次展开被守卫跳过、UI 卡"加载中"死态。
        guard !Task.isCancelled else {
            detailLoadingIDs.remove(id)
            return
        }
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
        // 非法分支名在提交前拦下并提示(与内联建分支同一校验规则),不甩裸 git 报错给用户。
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
                    showNotice("创建分支失败：\(UserFacingError.message(for: error))", isError: true)
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

/// 提交行:标题 + hash/统计/作者/时间 + 行内操作;点击展开完整详情。
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
                    // 窄窗口压缩顺序里保作者不被截掉:时间/按钮本身定宽,优先让位给作者。
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
            // 行身份存续、仅滚出可视区时 @State 保留:先清 copied 再取消,只不复位会让对勾常亮(同 BranchSwitchRow)。
            copied = false
            resetTask?.cancel()
            resetTask = nil
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
