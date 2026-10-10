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
    /// 分支面板行内"向该分支创建 MR"（目标分支为末参，当前分支为源，不 Push）。
    let onCreateMergeRequestForBranch: (RepositorySyncState, RepositoryConfig, String) -> Void
    /// 打开常用链接（工作区级工具栏入口 + 仓库行「常用链接」子菜单共用），
    /// URL 解析与失败反馈由宿主协调器承担。
    let onOpenCommonLink: (CommonLink) -> Void
    /// 在浏览器打开仓库主页(仓库行右键/⋯ 菜单)。
    let onOpenRepositoryWeb: (RepositorySyncState, RepositoryConfig) -> Void
    let onDeleteRepository: (RepositorySyncState, String) -> Void
    let onTogglePinnedRepository: (RepositorySyncState) -> Void
    let onStashChanges: (RepositorySyncState, String) -> Void
    let onPopStash: (RepositorySyncState, GitStashEntry, String) -> Void
    let onDropStash: (RepositorySyncState, GitStashEntry, String) -> Void
    let onAbortInterruptedOperation: (RepositorySyncState, String) -> Void
    let onMergeDefaultBranchIntoCurrent: () -> Void
    let onSwitchAllRepositoriesToDefaultBranch: () -> Void
    let onSwitchAllRepositoriesToWorkBranch: () -> Void
    let onRefreshStatuses: () -> Void
    /// 扫描工作区目录,把用户手动拷入、列表里还没有的 Git 仓库纳入进来。
    let onDiskRefresh: () -> Void
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
    /// 删除确认弹窗内容:在删除按钮触发时刻做一次目录探测后写入。
    /// 不能按 body 求值现算——此前 .alert 参数直接读计算属性,每帧一次主线程 stat。
    @State private var deleteConfirmation: WorkplaceDeleteConfirmationState?
    @State private var periodicRefreshSeed = 0
    @State private var manualRefreshSeed = 0
    @State private var pendingRefreshFeedback: CCSpaceFeedback?
    @State private var branchRefreshTask: Task<Void, Never>?
    /// 分支刷新任务代际:任务体末尾只在"自己仍是最新一次排程"时才复位句柄。
    /// 否则被取消的旧任务晚于视图复现后的新任务收尾时,会把**新任务**的句柄抹成
    /// nil,下次排程再起一个并发加载器(同 RootSplitView 的 refreshGeneration 防线)。
    @State private var branchRefreshGeneration: UInt64 = 0
    @State private var hasQueuedBranchRefresh = false
    @State private var lastFocusRefreshTime: Date?
    @State private var hostWindow: NSWindow?
    /// 常驻轮询任务句柄:随场景阶段启停,视图消失时取消。
    @State private var periodicRefreshTask: Task<Void, Never>?
    /// scenePhase 的 @State 镜像:长驻任务捕获的是首帧视图拷贝,@Environment 的值
    /// 在拷贝上是冻结快照(同 RootSplitView 的做法),循环里读镜像才是当前值。
    @State private var mirroredScenePhase: ScenePhase = .active
    /// syncStates 的本地目录镜像:@State 走外部存储,长驻闭包里读到的是当前值,
    /// 不是首帧快照(镜像内容由 WorkplaceDetailLocalDirectoryMirror 求值)。
    @State private var localDirectoryMirror = WorkplaceDetailLocalDirectoryMirror(syncStates: [])
    /// 工作区目录探测结果:仅在没有任何同步态行时供"打开目录"可用性兜底。
    /// 后台异步探测写回,不让 fileExists 留在 body 求值链上(网盘/外置盘会卡主线程)。
    @State private var probedWorkplaceDirectoryExists = false
    /// presentationState.isActionLocked 的镜像:分支加载任务闭包读当前锁状态。
    @State private var mirroredIsActionLocked = false
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
            syncStates: syncStates,
            probedWorkplaceDirectoryExists: probedWorkplaceDirectoryExists
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

    @ViewBuilder
    private var feedbackBanner: some View {
        if let shownFeedback = feedback {
            CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
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
                // 排序含 localizedStandardCompare,同样不能进 ForEach 现算。
                let lookup = repositoryByID
                let sortedStates = sortedWorkplaceSyncStates
                repositorySection(
                    sortedStates: sortedStates,
                    lookup: lookup,
                    detailState: presentationState
                )
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
            if workplace.links.isEmpty == false {
                commonLinksToolbarItem(state.isActionLocked)
            }
            deleteToolbarItem(state)
        }
        .animation(.snappy(duration: 0.22), value: repositories.count)
        .animation(.snappy(duration: 0.22), value: syncStates.count)
        .alert(
            deleteConfirmation?.title ?? "",
            isPresented: $showingDeleteConfirmation
        ) {
            Button(deleteConfirmation?.confirmLabel ?? "确认删除", role: .destructive) {
                actions.onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteConfirmation?.message ?? "")
        }
        // 定时轮询用 .task 长循环驱动;Timer.publish 写在 body 里会随每次渲染
        // 重建、倒计时归零,交互频繁时轮询会被无限推迟。
        // 轮询仅在 scenePhase == .active 时运行:非活跃(应用退到后台)立即停表,
        // 回到活跃时立即刷一次并恢复定时器。
        .onAppear {
            // 镜像先于周期任务对齐(onChange 只在**变化**时触发,首帧必须补一次):
            // 分支刷新任务可能在 .task 之前就创建,那里同样只读镜像。
            mirroredScenePhase = scenePhase
        }
        .task {
            // @Environment 的值在 .task 执行时刻仍是当前值(闭包每次渲染重建),
            // 先同步镜像再启停;此后长驻循环只读镜像,不碰冻结的首帧拷贝。
            mirroredScenePhase = scenePhase
            syncPeriodicStatusRefresh()
        }
        // 目录存在性后台探测:结果只写入 @State,body 求值链零磁盘 IO。
        .task(id: workplace.path) {
            let path = workplace.path
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard Task.isCancelled == false else { return }
            probedWorkplaceDirectoryExists = exists
        }
        // 应用重新激活(从其他 App 切回)立即刷新并恢复轮询;退到后台停表。
        .onChange(of: scenePhase) { _, newPhase in
            mirroredScenePhase = newPhase
            guard newPhase == .active else {
                stopPeriodicStatusRefresh()
                return
            }
            triggerFocusDrivenStatusRefresh()
            syncPeriodicStatusRefresh()
        }
        // 长驻/异步闭包(轮询循环、分支加载任务)只读这两个 @State 镜像,
        // 不读视图拷贝上的 syncStates/presentationState 冻结快照;initial 保证挂载首帧就同步。
        .onChange(of: syncStates, initial: true) { _, states in
            localDirectoryMirror = WorkplaceDetailLocalDirectoryMirror(syncStates: states)
            syncActionLockedMirror(syncStates: states, isPerformingAction: isPerformingAction)
        }
        // isActionLocked = isPerformingAction || isBusy,而 isBusy 只依赖
        // syncStates 中匹配 workplace.id + 选中集合的行,以及 workplace.selectedRepositoryIDs
        // (repositories 只参与 failedRepositories 的 filter,对 isBusy 零影响,见
        // WorkplaceActionState)——这三条 onChange 合起来覆盖它的全部变化源,故不再单挂
        // .onChange(of: presentationState.isActionLocked):
        // 那会让 presentationState(构造 WorkplaceActionState:遍历全部 syncStates + 建 Set)
        // 每帧多算一次,把详情页热路径刚收敛下来的成本又加回去。
        .onChange(of: isPerformingAction, initial: true) { _, performing in
            syncActionLockedMirror(syncStates: syncStates, isPerformingAction: performing)
        }
        // 选中集合是 isBusy 的直接输入,此前却没有观察者——不出问题靠的是"选中变化 ⇒
        // syncStates 行集合变化"这条未写明的 Store 不变量;显式观察,不依赖它。
        .onChange(of: workplace.selectedRepositoryIDs, initial: true) { _, _ in
            syncActionLockedMirror(syncStates: syncStates, isPerformingAction: isPerformingAction)
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
        // 兜底:锁释放瞬间补一次快照重载。动作完成时的 invalidate 若恰好在
        // isActionLocked 仍为 true 的渲染帧里被消费,loadBranches 会被守卫跳过
        // 且不再有第二次 token 变化——分支面板对号停在旧值直到 30s 轮询。
        .onChange(of: presentationState.isActionLocked) { _, locked in
            guard locked == false else { return }
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
    /// 读 mirroredScenePhase(@State)而非 @Environment:后者在长驻闭包里是首帧快照。
    private func syncPeriodicStatusRefresh() {
        guard mirroredScenePhase == .active else {
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

    /// 同步 isActionLocked 镜像;只由上面三条 onChange 调用(带 initial,挂载首帧即同步),
    /// 不在 body 热路径上求值。式子与 WorkplaceDetailPresentationState.isActionLocked 同源
    /// (= isPerformingAction || actionState.isBusy),显式接收最新入参而非读闭包捕获的视图拷贝。
    private func syncActionLockedMirror(
        syncStates states: [RepositorySyncState],
        isPerformingAction performing: Bool
    ) {
        mirroredIsActionLocked = performing || WorkplaceActionState(
            workplace: workplace,
            repositories: repositories,
            syncStates: states
        ).isBusy
    }

    /// 常驻轮询 git 状态;仅在 App 活跃期间存在(由 scenePhase 门控启停)。
    /// 场景退出活跃时 onChange 会取消任务而退出循环,避免后台仍触发全量分支快照。
    /// 契约:循环内只读 @State 镜像(localDirectoryMirror 等),它们走外部存储,
    /// 任何时刻都是当前值;不要读 @Environment 或视图拷贝上的存储属性——那在
    /// 长驻任务捕获的首帧拷贝上是冻结快照,读不到实时值(启停仍依赖 .onChange
    /// 的取消与重建,循环只需响应 Task.sleep 的取消错误)。
    /// @MainActor:循环每拍直写 @State(periodicRefreshSeed/syncStates),
    /// 必须落在主执行器;Task.sleep 本身异步等待,不会阻塞主线程。
    @MainActor
    private func runPeriodicStatusRefresh() async {
        var lastSnapshotReload = Date.distantPast
        while true {
            do {
                try await Task.sleep(for: .seconds(WorkplaceDetailRefreshInterval.activeGitStatus))
            } catch {
                return // 任务被取消(视图销毁或退到后台),退出循环
            }
            guard localDirectoryMirror.hasAnyLocalDirectory else { continue }
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
                    .ccspaceQuickHelp("取消当前操作", providesLabel: true)
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

    /// 工作区级常用链接工具栏入口:仅在配置了链接时渲染。菜单项点击上抛宿主,
    /// URL 解析与失败反馈走协调器(与"打开仓库主页"同一口径)。
    /// 操作锁定期置灰:开链走协调器,忙时点击被静默丢弃,置灰比"点了没反应"诚实
    /// (10-10 review P2 修复)。
    private func commonLinksToolbarItem(_ isActionLocked: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(workplace.links) { link in
                    Button(link.title) { actions.onOpenCommonLink(link) }
                }
            } label: {
                Image(systemName: "link")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("常用链接")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(isActionLocked)
            .ccspaceQuickHelp("打开本工作区的常用链接")
        }
    }

    private func deleteToolbarItem(_ state: WorkplaceDetailPresentationState) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                // 目录探测收敛到触发时刻,每次点击只 stat 一次,body 路径零 IO。
                deleteConfirmation = WorkplaceDeleteConfirmationState(
                    workplace: workplace,
                    directoryPath: existingDirectoryPath(workplace.path)
                )
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

    /// @MainActor:await 分支加载回来后直写 @State(branchSnapshots),
    /// 需在主执行器落笔;快照加载本体仍在后台执行。
    /// 返回值表示本轮是否真正完成了加载:被动作锁/非活跃跳过的轮次不得据此
    /// 展示"已刷新"提示。
    @MainActor
    private func loadBranches() async -> Bool {
        // 读 @State 镜像而非视图拷贝上的存储属性:本方法由分支刷新任务的
        // 长驻闭包调用,拷贝里的 syncStates/scenePhase/isActionLocked 是首帧冻结值。
        let localSyncStates = localDirectoryMirror.localDirectoryStates
        guard localSyncStates.isEmpty == false else {
            branchSnapshots = [:]
            return true
        }
        guard mirroredScenePhase == .active else { return false }
        guard mirroredIsActionLocked == false else { return false }

        let snapshots = await WorkplaceBranchLoader.loadBranchSnapshots(
            for: localSyncStates,
            gitService: gitService
        )
        guard Task.isCancelled == false else { return false }
        branchSnapshots = WorkplaceBranchSnapshotMerge.merge(
            attemptedKeys: localSyncStates.map { RepositoryBranchCacheKey(state: $0) },
            fresh: snapshots,
            previous: branchSnapshots
        )
        return true
    }

    private func scheduleBranchSnapshotRefresh() {
        guard branchRefreshTask == nil else {
            hasQueuedBranchRefresh = true
            return
        }

        branchRefreshGeneration += 1
        let generation = branchRefreshGeneration
        branchRefreshTask = Task { @MainActor in
            var didLoadSnapshots = false
            repeat {
                hasQueuedBranchRefresh = false
                didLoadSnapshots = await loadBranches() || didLoadSnapshots
            } while hasQueuedBranchRefresh && Task.isCancelled == false

            // 手动刷新的反馈在刷新真正完成后展示,避免"已刷新"先于刷新发生;
            // 本轮全部被动作锁/非活跃跳过时不展示,防止误报。任务被取消时保留
            // 待展示反馈,交给下一次排队加载(如锁释放兜底补刷)消费。
            // 反馈与句柄复位都以"未被取消"为前提:被取消说明已有更新的排程接管,
            // 旧任务不得回写 @State,更不能把新任务句柄抹成 nil(代际守卫)。
            if Task.isCancelled == false, generation == branchRefreshGeneration {
                if let pending = pendingRefreshFeedback {
                    if didLoadSnapshots {
                        feedback = pending
                    }
                    pendingRefreshFeedback = nil
                }
                branchRefreshTask = nil
            }
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

    /// sortedStates 由调用方在 body 顶部求值一次后传入,避免每轮重复排序。
    private func repositorySection(
        sortedStates: [RepositorySyncState],
        lookup: [UUID: RepositoryConfig],
        detailState: WorkplaceDetailPresentationState
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 不再渲染"Git 仓库"区块标题(10-10 用户要求):详情页只此一区,标题冗余。
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
                    ForEach(sortedStates) { state in
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
            onCreateMergeRequestForBranch: { repository, targetBranch in
                actions.onCreateMergeRequestForBranch(state, repository, targetBranch)
            },
            onOpenCommonLink: { link in
                actions.onOpenCommonLink(link)
            },
            onOpenRepositoryWeb: { repository in
                actions.onOpenRepositoryWeb(state, repository)
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
            onPopStash: { entry in
                actions.onPopStash(state, entry, repositoryName)
            },
            onDropStash: { entry in
                actions.onDropStash(state, entry, repositoryName)
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
            // 整区刷新顺带扫一次目录:用户手动拷进来的仓库否则要等 App 切回前台
            // 或 120 秒定时刷新才出现,点「刷新」却刷不出来最容易被当成没生效。
            actions.onDiskRefresh()
        }
        actions.onRefreshStatuses()
        manualRefreshSeed += 1
    }
}

/// 分支快照按 key 合并:本轮取数失败(快照缺失)的 key 沿用上一轮结果,
/// 避免 30s 轮询中偶发 git 失败把该行分支信息整体抹掉;未参与本轮取数的 key
/// (目录消失/仓库移除)不保留,快照字典不随历史无限膨胀。
enum WorkplaceBranchSnapshotMerge {
    static func merge(
        attemptedKeys: [RepositoryBranchCacheKey],
        fresh: [RepositoryBranchCacheKey: RepositoryBranchSnapshot],
        previous: [RepositoryBranchCacheKey: RepositoryBranchSnapshot]
    ) -> [RepositoryBranchCacheKey: RepositoryBranchSnapshot] {
        var merged: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
        merged.reserveCapacity(attemptedKeys.count)
        for key in attemptedKeys {
            merged[key] = fresh[key] ?? previous[key]
        }
        return merged
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
