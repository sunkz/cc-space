import SwiftUI
import AppKit

private enum WorkplaceDetailRefreshInterval {
    /// 轮询 tick 间隔:应用激活期间的常驻心跳。
    static let activeGitStatus: TimeInterval = 5
    /// 分支快照(含状态角标)的最小重载间隔。
    ///
    /// 每次重载对每个本地仓库各起一个 git 进程。此前跟着 5 秒心跳走,10 仓库的
    /// 工作区就是每分钟 100+ 次 fork/exec;角标(领先/落后/未提交)延迟 30 秒
    /// 完全可接受,进程数降到 1/6。
    static let branchSnapshotReload: TimeInterval = 30
    /// 聚焦等事件触发刷新的最小间隔,避免连续通知造成重复加载。
    static let minFocusEventInterval: TimeInterval = 2
}

struct WorkplaceDetailActions {
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRetry: (RepositoryConfig) -> Void
    let onPullAll: () -> Void
    let onPush: () -> Void
    let onPull: (RepositoryConfig) -> Void
    let onPushRepository: (RepositorySyncState, String) -> Void
    let onSwitchBranch: (RepositorySyncState, String, String) -> Void
    /// 新建分支:末参为基线种类(分支行尾 ➕ 所在分支,本地/远端两页签均可创建),
    /// `.currentHead` 表示基于当前 HEAD。
    let onCreateBranch: (RepositorySyncState, String, String, BranchBaseKind) -> Void
    let onDeleteBranch: (RepositorySyncState, String, String, String?) -> Void
    let onDeleteRemoteBranch: (RepositorySyncState, String, String) -> Void
    let onSwitchRepositoryToDefaultBranch: (RepositorySyncState, String) -> Void
    let onSwitchRepositoryToWorkBranch: (RepositorySyncState, String) -> Void
    let onMergeRepositoryDefaultBranchIntoCurrent: (RepositorySyncState, String) -> Void
    let onCreateMergeRequest: (RepositorySyncState, RepositoryConfig, String?) -> Void
    let onDeleteRepository: (RepositorySyncState, String) -> Void
    let onTogglePinnedRepository: (RepositorySyncState) -> Void
    let onStashChanges: (RepositorySyncState, String) -> Void
    let onPopStash: (RepositorySyncState, Int, String) -> Void
    let onDropStash: (RepositorySyncState, Int, String) -> Void
    let onAbortInterruptedOperation: (RepositorySyncState, String) -> Void
    let onMergeDefaultBranchIntoCurrent: () -> Void
    let onSwitchAllRepositoriesToDefaultBranch: () -> Void
    let onSwitchAllRepositoriesToWorkBranch: () -> Void
    let onRefreshStatuses: () -> Void
    let onCancelAction: () -> Void
}

struct WorkplaceDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    let workplace: Workplace
    let repositories: [RepositoryConfig]
    let syncStates: [RepositorySyncState]
    let actions: WorkplaceDetailActions
    let isPerformingAction: Bool
    let branchRefreshSeed: Int
    let gitService: GitServicing
    /// 打开方式菜单的编辑器/终端列表,由根视图的 OpenActionsModel 定期刷新注入。
    let installedEditors: [ExternalEditor]
    let installedTerminals: [ExternalEditor]
    let preferredOpenActionID: String?
    let onSelectOpenAction: (String) -> Void
    @Binding var feedback: CCSpaceFeedback?
    @State private var branchSnapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
    @State private var showingDeleteConfirmation = false
    @State private var periodicRefreshSeed = 0
    @State private var manualRefreshSeed = 0
    @State private var pendingRefreshFeedback: CCSpaceFeedback?
    @State private var branchRefreshTask: Task<Void, Never>?
    @State private var hasQueuedBranchRefresh = false
    @State private var lastFocusRefreshTime: Date?
    @State private var hostWindow: NSWindow?
    /// 常驻轮询任务句柄:随场景阶段启停,视图消失时取消。
    @State private var periodicRefreshTask: Task<Void, Never>?
    /// 行视图共用的仓库信息服务。struct View 无稳定生命周期:SwiftUI 每次父视图
    /// 重渲染都会重新执行 init 重建实例(纯值类型、Sendable,行为无害),
    /// 这里只是避免同一次求值内每行各建一份,不要把它当有状态的长期持有物。
    private let repositoryInfoService: RepositoryInfoService

    private var repositoryByID: [UUID: RepositoryConfig] {
        // 导入的备份 JSON 理论上可能含重复 id,uniqueKeysWithValues 会直接 trap;
        // 循环构建时后者覆盖前者即可。
        var lookup = Dictionary<UUID, RepositoryConfig>(minimumCapacity: repositories.count)
        for repository in repositories {
            lookup[repository.id] = repository
        }
        return lookup
    }

    private var sortedWorkplaceSyncStates: [RepositorySyncState] {
        WorkplaceRepositorySorting.sortRepositorySyncStates(
            syncStates,
            pinnedRepositoryIDs: workplace.pinnedRepositoryIDs
        )
    }

    private var actionState: WorkplaceActionState {
        WorkplaceActionState(
            workplace: workplace,
            repositories: repositories,
            syncStates: syncStates
        )
    }

    private var openActions: [OpenActionItem] {
        WorkplaceSystemActions.allOpenActions(
            editors: installedEditors,
            terminals: installedTerminals
        )
    }

    private var preferredOpenAction: OpenActionItem {
        WorkplaceSystemActions.preferredOpenAction(
            id: preferredOpenActionID,
            editors: installedEditors,
            terminals: installedTerminals
        )
    }

    private var presentationState: WorkplaceDetailPresentationState {
        WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: isPerformingAction
        )
    }

    private var deleteConfirmationState: WorkplaceDeleteConfirmationState {
        WorkplaceDeleteConfirmationState(workplace: workplace)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let feedback {
            CCSpaceFeedbackBanner(feedback: feedback)
                .transition(.move(edge: .top).combined(with: .opacity))
                .ccspaceAutoDismissFeedback($feedback)
        }
    }

    private var branchRefreshToken: Int {
        var hasher = Hasher()
        for state in syncStates {
            hasher.combine(state.repositoryID)
            hasher.combine(state.localPath)
            hasher.combine(state.status)
            hasher.combine(state.lastError)
            hasher.combine(state.lastSyncedAt)
        }
        hasher.combine(workplace.branch)
        hasher.combine(branchRefreshSeed)
        hasher.combine(periodicRefreshSeed)
        hasher.combine(manualRefreshSeed)
        return hasher.finalize()
    }

    private func repoDisplayName(
        for state: RepositorySyncState,
        lookup: [UUID: RepositoryConfig]
    ) -> String {
        if let config = lookup[state.repositoryID] {
            return config.repoName
        }
        return URL(fileURLWithPath: state.localPath).lastPathComponent
    }

    init(
        workplace: Workplace,
        repositories: [RepositoryConfig],
        syncStates: [RepositorySyncState],
        gitService: GitServicing,
        actions: WorkplaceDetailActions,
        isPerformingAction: Bool = false,
        branchRefreshSeed: Int = 0,
        feedback: Binding<CCSpaceFeedback?> = .constant(nil),
        installedEditors: [ExternalEditor],
        installedTerminals: [ExternalEditor],
        preferredOpenActionID: String?,
        onSelectOpenAction: @escaping (String) -> Void
    ) {
        self.workplace = workplace
        self.repositories = repositories
        self.syncStates = syncStates
        self.gitService = gitService
        self.actions = actions
        self.isPerformingAction = isPerformingAction
        self.branchRefreshSeed = branchRefreshSeed
        self._feedback = feedback
        self.installedEditors = installedEditors
        self.installedTerminals = installedTerminals
        self.preferredOpenActionID = preferredOpenActionID
        self.onSelectOpenAction = onSelectOpenAction
        self.repositoryInfoService = RepositoryInfoService(gitService: gitService)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 每轮 body 求值只构建一次,沿渲染路径下发给每一行/toolbar。
                let lookup = repositoryByID
                repositorySection(lookup: lookup, detailState: presentationState)
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(12)
        }
        .overlay(alignment: .top) {
            feedbackBanner
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 6)
                .animation(.snappy(duration: 0.25), value: feedback)
        }
        .ccspaceScreenBackground()
        .navigationTitle(workplace.name)
        .toolbar {
            // 只构建一次并沿渲染路径下发:此前 9 个 toolbar 项各自访问
            // presentationState,每次 body 求值重算 9 遍 WorkplaceActionState
            // (遍历全部 syncStates + 建 Set + filter),是详情页最热的路径。
            let state = presentationState
            operationProgressToolbarItem(state)
            editToolbarItem(state)
            refreshToolbarItem(state)
            pullToolbarItem(state)
            pushToolbarItem(state)
            branchToolbarItems(state)
            openActionToolbarItem(state)
            deleteToolbarItem(state)
        }
        .animation(.snappy(duration: 0.22), value: repositories.count)
        .animation(.snappy(duration: 0.22), value: syncStates.count)
        .alert(
            deleteConfirmationState.title,
            isPresented: $showingDeleteConfirmation
        ) {
            Button(deleteConfirmationState.confirmLabel, role: .destructive) {
                actions.onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteConfirmationState.message)
        }
        // 定时轮询用 .task 长循环驱动;Timer.publish 写在 body 里会随每次渲染
        // 重建、倒计时归零,交互频繁时轮询会被无限推迟。
        // 轮询仅在 scenePhase == .active 时运行:非活跃(应用退到后台)立即停表,
        // 回到活跃时立即刷一次并恢复定时器。
        .task {
            syncPeriodicStatusRefresh()
        }
        // 应用重新激活(从其他 App 切回)立即刷新并恢复轮询;退到后台停表。
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                stopPeriodicStatusRefresh()
                return
            }
            triggerFocusDrivenStatusRefresh()
            syncPeriodicStatusRefresh()
        }
        // 本窗口重新获得焦点(如在 IDE/终端提交后切回)立即刷新;
        // 按 hostWindow 过滤,Diff 等其他窗口成为 key 不再触发全量刷新。
        .background(HostWindowReader { hostWindow = $0 })
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { note in
            guard (note.object as? NSWindow) == hostWindow else { return }
            triggerFocusDrivenStatusRefresh()
        }
        .onChange(of: branchRefreshToken, initial: true) { _, _ in
            scheduleBranchSnapshotRefresh()
        }
        .onDisappear {
            stopPeriodicStatusRefresh()
            branchRefreshTask?.cancel()
            branchRefreshTask = nil
            hasQueuedBranchRefresh = false
            // 不要跨视图生命周期强持有 NSWindow。
            hostWindow = nil
        }
    }

    /// 按当前场景阶段启停常驻轮询:活跃且任务未运行则启动,否则停表。
    private func syncPeriodicStatusRefresh() {
        guard scenePhase == .active else {
            stopPeriodicStatusRefresh()
            return
        }
        guard periodicRefreshTask == nil else { return }
        periodicRefreshTask = Task { await runPeriodicStatusRefresh() }
    }

    private func stopPeriodicStatusRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
    }

    /// 常驻轮询 git 状态;仅在 App 活跃期间存在(由 scenePhase 门控启停)。
    /// 场景退出活跃时任务会被取消而退出循环,避免后台仍触发全量分支快照。
    private func runPeriodicStatusRefresh() async {
        var lastSnapshotReload = Date.distantPast
        while true {
            do {
                try await Task.sleep(for: .seconds(WorkplaceDetailRefreshInterval.activeGitStatus))
            } catch {
                return // 任务被取消(视图销毁或退到后台),退出循环
            }
            guard scenePhase == .active else { return }
            guard syncStates.contains(where: \.hasLocalDirectory) else { continue }
            // 分支快照按最小间隔节流推进,不跟着 5 秒心跳每次都重载。
            let now = Date()
            guard now.timeIntervalSince(lastSnapshotReload)
                >= WorkplaceDetailRefreshInterval.branchSnapshotReload else { continue }
            lastSnapshotReload = now
            periodicRefreshSeed += 1
        }
    }

    private func editToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onEdit()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("编辑工作区")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canEditWorkplace)
            .ccspaceQuickHelp(state.editHelp)
        }
    }

    @ToolbarContentBuilder
    private func operationProgressToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        if state.showsOperationProgress {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Button {
                        actions.onCancelAction()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .ccspaceQuickHelp("取消当前操作")
                }
                .frame(minWidth: 30, minHeight: 28)
                .padding(.horizontal, 2)
            }
        }
    }

    private func pushToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onPush()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Push 所有仓库")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canPushAllRepositories)
            .ccspaceQuickHelp(state.pushHelp)
        }
    }

    private func refreshToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                requestStatusRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新全部仓库状态")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canRefreshAllRepositories)
            .ccspaceQuickHelp(state.refreshHelp)
        }
    }

    private func pullToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onPullAll()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Pull 所有仓库")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canSyncAllRepositories)
            .ccspaceQuickHelp(state.syncHelp)
        }
    }

    /// 分支相关的一组工具栏按钮;单独成组避免 toolbar 构建器子项超限。
    @ToolbarContentBuilder
    private func branchToolbarItems(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        switchAllToDefaultBranchToolbarItem(state)
        switchAllToWorkBranchToolbarItem(state)
    }

    private func switchAllToDefaultBranchToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onSwitchAllRepositoriesToDefaultBranch()
            } label: {
                Label("切到默认分支", systemImage: "arrow.uturn.backward.circle")
            }
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canSwitchRepositoriesToDefaultBranch)
            .ccspaceQuickHelp(state.switchDefaultBranchHelp)
        }
    }

    private func switchAllToWorkBranchToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onSwitchAllRepositoriesToWorkBranch()
            } label: {
                Label("切到工作分支", systemImage: "hammer.circle")
            }
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canSwitchRepositoriesToWorkBranch)
            .ccspaceQuickHelp(state.switchWorkBranchHelp)
        }
    }

    private func openActionToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(openActions) { action in
                    Button {
                        handleOpenAction(action, at: workplace.path)
                    } label: {
                        Label {
                            Text(action.displayName)
                        } icon: {
                            Image(nsImage: action.icon)
                        }
                    }
                }
                // macOS 26 菜单默认不渲染 Label 图标,显式要求标题+图标。
                .labelStyle(.titleAndIcon)
            } label: {
                Image(nsImage: preferredOpenAction.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            } primaryAction: {
                handleOpenAction(preferredOpenAction, at: workplace.path)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("在 \(preferredOpenAction.displayName) 中打开")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canOpenDirectory)
            .ccspaceQuickHelp("在 \(preferredOpenAction.displayName) 中打开")
        }
    }

    private func deleteToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("删除工作区")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!state.canDeleteWorkplace)
            .ccspaceQuickHelp(state.deleteHelp)
        }
    }

    private func loadBranches() async {
        let localSyncStates = syncStates.filter(\.hasLocalDirectory)
        guard localSyncStates.isEmpty == false else {
            branchSnapshots = [:]
            return
        }
        guard scenePhase == .active else { return }
        guard presentationState.isActionLocked == false else { return }

        let snapshots = await WorkplaceBranchLoader.loadBranchSnapshots(
            for: localSyncStates,
            gitService: gitService
        )
        guard Task.isCancelled == false else { return }
        branchSnapshots = snapshots
    }

    private func scheduleBranchSnapshotRefresh() {
        guard branchRefreshTask == nil else {
            hasQueuedBranchRefresh = true
            return
        }

        branchRefreshTask = Task { @MainActor in
            repeat {
                hasQueuedBranchRefresh = false
                await loadBranches()
            } while hasQueuedBranchRefresh && Task.isCancelled == false

            // 手动刷新的反馈在刷新真正完成后展示,避免"已刷新"先于刷新发生。
            if let pending = pendingRefreshFeedback, Task.isCancelled == false {
                feedback = pending
                pendingRefreshFeedback = nil
            }
            branchRefreshTask = nil
        }
    }

    /// 聚焦类事件驱动的立即刷新;做最小间隔节流,重复触发时依赖分支加载任务的排队去重。
    private func triggerFocusDrivenStatusRefresh() {
        guard syncStates.contains(where: \.hasLocalDirectory) else { return }
        if let lastFocusRefreshTime,
           Date.now.timeIntervalSince(lastFocusRefreshTime)
               < WorkplaceDetailRefreshInterval.minFocusEventInterval {
            return
        }
        lastFocusRefreshTime = .now
        periodicRefreshSeed += 1
    }

    private func repositorySection(
        lookup: [UUID: RepositoryConfig],
        detailState: WorkplaceDetailPresentationState
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            if syncStates.isEmpty {
                CCSpaceEmptyStateCard(
                    title: "暂无仓库",
                    subtitle: "点击编辑按钮添加仓库到此工作区",
                    systemImage: "shippingbox",
                    tint: .accentColor
                ) {
                    Button("编辑") {
                        actions.onEdit()
                    }
                    .ccspacePrimaryActionButton()
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(sortedWorkplaceSyncStates) { state in
                        repositoryRow(for: state, lookup: lookup, detailState: detailState)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        }
    }

    /// 单行仓库卡片;参数较多,独立成函数避免 ViewBuilder 表达式类型检查超时。
    /// lookup/state 由调用方沿渲染路径传入(每轮 body 求值各构建一次),
    /// 否则 ForEach 每行各建一份字典/状态,退化为 O(N²)。
    private func repositoryRow(
        for state: RepositorySyncState,
        lookup: [UUID: RepositoryConfig],
        detailState: WorkplaceDetailPresentationState
    ) -> some View {
        let branchSnapshot = branchSnapshots[RepositoryBranchCacheKey(state: state)]
        let repository = lookup[state.repositoryID]
        let workBranch = workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryName = repoDisplayName(for: state, lookup: lookup)
        return WorkplaceRepositoryRowView(
            state: state,
            repository: repository,
            displayName: repositoryName,
            isPinned: workplace.pinnedRepositoryIDs.contains(state.repositoryID),
            currentBranch: branchSnapshot?.currentBranch,
            branchStatus: branchSnapshot?.status,
            availableBranches: branchSnapshot?.branches ?? [],
            retryRepository: repository,
            pullRepository: repository,
            allowsDeleteRepository: workplace.selectedRepositoryIDs.count > 1,
            onRetry: actions.onRetry,
            onRefreshStatus: {
                requestStatusRefresh(repositoryName: repositoryName)
            },
            onPull: actions.onPull,
            onPush: {
                actions.onPushRepository(state, repositoryName)
            },
            onSwitchBranch: { branch in
                actions.onSwitchBranch(state, repositoryName, branch)
            },
            onCreateBranch: { branch, base in
                actions.onCreateBranch(state, repositoryName, branch, base)
            },
            onDeleteBranch: { branch, remoteBranch in
                actions.onDeleteBranch(state, repositoryName, branch, remoteBranch)
            },
            onDeleteRemoteBranch: { branch in
                actions.onDeleteRemoteBranch(state, repositoryName, branch)
            },
            onSwitchToDefaultBranch: {
                actions.onSwitchRepositoryToDefaultBranch(state, repositoryName)
            },
            onSwitchToWorkBranch: {
                guard let workBranch, workBranch.isEmpty == false else { return }
                actions.onSwitchRepositoryToWorkBranch(state, repositoryName)
            },
            showsWorkBranchAction: workBranch?.isEmpty == false,
            onMergeDefaultBranchIntoCurrent: {
                actions.onMergeRepositoryDefaultBranchIntoCurrent(state, repositoryName)
            },
            onCreateMergeRequest: { repository, targetBranch in
                actions.onCreateMergeRequest(state, repository, targetBranch)
            },
            actionsDisabled: detailState.isActionLocked,
            openActions: openActions,
            preferredOpenAction: preferredOpenAction,
            onOpenAction: handleOpenAction,
            infoService: repositoryInfoService,
            onDelete: {
                actions.onDeleteRepository(state, repositoryName)
            },
            onTogglePinned: {
                actions.onTogglePinnedRepository(state)
            },
            onStash: {
                actions.onStashChanges(state, repositoryName)
            },
            onPopStash: { index in
                actions.onPopStash(state, index, repositoryName)
            },
            onDropStash: { index in
                actions.onDropStash(state, index, repositoryName)
            },
            onAbortInterruptedOperation: {
                actions.onAbortInterruptedOperation(state, repositoryName)
            }
        )
    }
    
    private func handleOpenAction(_ action: OpenActionItem, at path: String) {
        onSelectOpenAction(action.id)
        do {
            try WorkplaceSystemActions.performOpenAction(action, at: path)
        } catch {
            feedback = WorkplaceDetailFeedbackFactory.actionError(
                action: "打开 \(action.displayName)",
                error: error
            )
        }
    }

    private func requestStatusRefresh(repositoryName: String? = nil) {
        guard presentationState.canRefreshAllRepositories else { return }
        if let repositoryName {
            pendingRefreshFeedback = WorkplaceDetailFeedbackFactory.refreshRepositoryStatus(
                repositoryName: repositoryName
            )
        } else {
            pendingRefreshFeedback = WorkplaceDetailFeedbackFactory.refreshAllRepositoryStatuses(
                repositoryCount: syncStates.filter(\.hasLocalDirectory).count
            )
        }
        actions.onRefreshStatuses()
        manualRefreshSeed += 1
    }
}

/// 读取宿主 NSWindow 的轻量探针:视图挂入窗口后回调一次,
/// 用于把系统窗口通知过滤到"本视图所在的窗口"。
private struct HostWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowProbeView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbeView: NSView {
        let onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            onChange(window)
        }
    }
}
