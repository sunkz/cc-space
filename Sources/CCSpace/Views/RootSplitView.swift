import os
import SwiftUI

private let rootSplitViewLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RootSplitView"
)

struct RootSplitView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// scenePhase 的 @State 镜像:长驻 `.task` 闭包捕获的是挂载时刻的**视图结构体拷贝**,
    /// `@Environment` 的值在拷贝上是冻结的——周期任务里直接读 scenePhase 永远看到启动瞬间
    /// 的快照(active 判定整体失效)。@State 读写走外部存储,任何时刻读到的都是当前值。
    /// onAppear/onChange 双点同步,保证镜像与真实环境一致。
    @State private var mirroredScenePhase: ScenePhase = .active
    /// 磁盘刷新任务世代号:被取消的旧任务晚于新任务返回时,若无条件清 refreshTask
    /// 会把**新任务**的句柄抹掉,后续调度 guard 放行、并发磁盘刷新。
    @State private var refreshGeneration: UInt64 = 0
    /// 设置页当前页签:tab 栏挂在标题栏 principal 位置,状态放在根视图共享给 SettingsView。
    @State private var settingsTab: SettingsTab = .general
    @StateObject private var appViewModel = AppViewModel()
    @StateObject private var detailActionCoordinator = WorkplaceDetailActionCoordinator()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var openActionsModel = OpenActionsModel()
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var repositoryStore: RepositoryStore
    @StateObject private var workplaceStore: WorkplaceStore
    @State private var editingWorkplace: Workplace?
    @State private var createWorkplaceSheet: WorkplaceCreateSheetPresentation?
    @State private var refreshTask: Task<Void, Never>?
    @State private var hasAppliedLaunchConfiguration = false
    @State private var showOnboarding = false
    /// 外观切换保存失败时的可见提示(挂在根视图顶层,设置页工具栏操作也能看到)。
    @State private var appearanceFeedback: CCSpaceFeedback?
    /// 待展示的去重清理提示:去重事件随时可能发生,横幅同一时刻只挂一条,
    /// 事件先入队、横幅空出后补放(纯逻辑见 DeduplicationNoticeQueue)。
    @State private var deduplicationNotices = DeduplicationNoticeQueue()
    private let launchConfiguration: CCSpaceLaunchConfiguration
    private let syncCoordinator: SyncCoordinator
    private let gitService: GitService
    private let aiService: AIServiceInfoServicing

    private var selectedWorkplace: Workplace? {
        guard let selectedID = appViewModel.selectedWorkplaceID else { return nil }
        return workplaceStore.workplaces.first { $0.id == selectedID }
    }

    private var shouldShowOnboarding: Bool {
        !settingsStore.settings.hasCompletedOnboarding
            && settingsStore.settings.workplaceRootPath.isEmpty
            && repositoryStore.repositories.isEmpty
            && workplaceStore.workplaces.isEmpty
    }

    private var workplaceEditService: WorkplaceEditService {
        WorkplaceEditService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            syncCoordinator: syncCoordinator,
            gitService: gitService
        )
    }

    private var workplaceCreateService: WorkplaceCreateService {
        WorkplaceCreateService(
            repositoryStore: repositoryStore,
            workplaceStore: workplaceStore,
            syncCoordinator: syncCoordinator
        )
    }

    private var workplaceRuntimeService: WorkplaceRuntimeService {
        RootSplitRuntimeServices.makeWorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: syncCoordinator,
            settings: settingsStore.settings
        )
    }

    private var updatePresentationState: SettingsUpdatePresentationState {
        SettingsUpdatePresentationState(
            currentVersion: updateChecker.currentVersion,
            latestVersion: updateChecker.latestVersion,
            isChecking: updateChecker.isChecking,
            lastErrorMessage: updateChecker.lastErrorMessage
        )
    }

    private var diskRefreshService: DiskRefreshService {
        DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore
        )
    }

    init(
        launchConfiguration: CCSpaceLaunchConfiguration = CCSpaceLaunchConfiguration(),
        gitService: GitService = GitService(),
        aiService: AIServiceInfoServicing
    ) {
        self.launchConfiguration = launchConfiguration

        let fileStore = JSONFileStore(
            rootDirectory: launchConfiguration.resolvedAppSupportDirectory()
        )
        // 三个 Store 必须在 StateObject(wrappedValue:) 的 autoclosure 内惰性构造:
        // 先 `let instance = Store(...)` 再塞进去会让 autoclosure 的延迟语义失效,
        // 视图结构体每次重建都同步读盘(损坏文件还会触发 preserveCorruptFile 副作用)
        // 而实例随即被丢弃。三者互不依赖(SettingsStore 的换根在调用时才传入
        // WorkplaceStore),可以各自独立惰性构造。
        // autoclosure 在视图生命周期内只求值一次 → SettingsStore.init 只跑一次,
        // 其末尾的 API Key 迁移/钥匙串回填因此是"每启动一次",且早于 body 里任何
        // 读 `aiSettings.apiKey` 的消费方(时序见 SettingsStore.init 注释)。
        _settingsStore = StateObject(wrappedValue: SettingsStore(fileStore: fileStore))
        _repositoryStore = StateObject(wrappedValue: RepositoryStore(fileStore: fileStore))
        _workplaceStore = StateObject(wrappedValue: WorkplaceStore(fileStore: fileStore))
        self.gitService = gitService
        self.aiService = aiService
        syncCoordinator = SyncCoordinator(gitService: gitService)

        let appViewModel = AppViewModel()
        // 路由持久化回调在 onAppear 注入(见 bindRoutePersistenceCallbacks):
        // 此处拿不到 SwiftUI 实际持有的那个 SettingsStore(它还在 autoclosure 里),
        // 提前构造实例正是要消灭的重复读盘。AppViewModel 仍是路由的唯一事实来源,
        // 写 settings.json 镜像由其内部触发,View 修饰链不承担持久化职责。
        _appViewModel = StateObject(wrappedValue: appViewModel)

        // 首帧外观:直接读盘一次并应用(仅进程内第一次构造执行)。
        // 不能读 _settingsStore.wrappedValue——那会强制求值 autoclosure,
        // 视图结构体每次重建都新造一个 SettingsStore 又丢弃(白白同步读盘,
        // 且 corrupt 文件还会触发 preserveCorruptFile 副作用)。
        // onAppear 里的 reconcileOverride 兜底后续变更与 SwiftUI 实际持有的实例。
        // View init 必在主线程执行,但编译器无法证明——assumeIsolated 显式声明。
        MainActor.assumeIsolated {
            guard Self.hasAppliedLaunchAppearance == false else { return }
            Self.hasAppliedLaunchAppearance = true
            let persistedMode = (try? fileStore.loadIfPresent(
                AppSettings.self,
                from: "settings.json",
                default: AppSettings(workplaceRootPath: "")
            ))?.appearanceMode ?? .system
            AppearanceModeApplier.reconcileOverride(with: persistedMode)
        }
    }

    /// 首帧外观只应用一次;@MainActor 隔离由编译器强制主线程访问,
    /// View 构造虽然总在主线程,但需经 assumeIsolated 声明后才能触达。
    @MainActor private static var hasAppliedLaunchAppearance = false

    var body: some View {
        rootSheetModifiers(
            rootLifecycleModifiers(
                NavigationSplitView {
                    SidebarView(
                        appViewModel: appViewModel,
                        workplaceStore: workplaceStore,
                        syncStates: workplaceStore.syncStates,
                        hasUpdate: updateChecker.hasUpdate,
                        onCreateWorkplace: {
                            presentCreateWorkplace()
                        },
                        onTogglePinned: { workplace in
                            togglePinned(for: workplace)
                        },
                        onDuplicateWorkplace: { workplace in
                            duplicateWorkplace(workplace)
                        },
                        onToggleArchived: { workplace in
                            toggleArchived(for: workplace)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 340)
                } detail: {
                    switch appViewModel.route {
                    case .settings:
                        SettingsView(
                            settingsStore: settingsStore,
                            repositoryStore: repositoryStore,
                            workplaceStore: workplaceStore,
                            gitService: gitService,
                            aiService: aiService,
                            showOnboarding: $showOnboarding,
                            selectedTab: $settingsTab
                        )
                    case .workplaces:
                        if let workplace = selectedWorkplace {
                            detailView(for: workplace)
                        } else {
                            emptyWorkplaceState
                        }
                    }
                }
                .toolbar {
                    settingsTabToolbarItem
                    settingsToolbarItem
                }
                .navigationSplitViewStyle(.balanced)
                .frame(minWidth: 680, minHeight: 480)
            )
        )
    }

    /// 生命周期/定时刷新修饰单独成链:body 的单条修饰链过长会触发类型检查超时。
    private func rootLifecycleModifiers(_ content: some View) -> some View {
        content
            .task {
                await updateChecker.check()
            }
            // 周期任务用 .task 长循环驱动;Timer.publish 写在 body 修饰链里会随
            // 每次渲染重建,倒计时反复归零,周期任务事实失效。
            .task {
                // 启动校正:老数据缺 hasLocalDirectory key,依赖磁盘刷新修正可能永不触发。
                await workplaceStore.reconcileHasLocalDirectoryFlags()
            }
            .task {
                await runPeriodicUpdateCheck()
            }
            .task {
                await runPeriodicDiskRefresh()
            }
            .background(EffectiveAppearanceObserver(onChange: handleEffectiveAppearanceChange))
            .onAppear {
                // 镜像先于一切周期任务对齐(onChange 只在**变化**时触发,首帧必须补一次)。
                mirroredScenePhase = scenePhase
                // 反馈通道的选中项读取器:动作完成后据此判断用户是否已切走,
                // 不把 A 工作区的"已同步/失败"弹在 B 的详情页上。
                detailActionCoordinator.selectedWorkplaceIDProvider = { [appViewModel] in
                    appViewModel.selectedWorkplaceID
                }
                // 路由持久化回调必须先于下面任何会改路由的动作(否则首个回调
                // 找不到落点)。API Key 迁移不再挂这里:它随 SettingsStore 构造完成
                // (StateObject 首次求值,早于 AISettingsSection 的 @State 首帧取值),
                // 挪到 onAppear 已经晚于首帧,曾导致输入框捕获空 Key。
                bindRoutePersistenceCallbacks()
                // 启动恢复持久化的外观;覆盖若已被外部清空(显式模式下即不一致)会在此重新应用。
                AppearanceModeApplier.reconcileOverride(with: settingsStore.settings.appearanceMode)
                applyLaunchConfigurationIfNeeded()
                restoreLastSelectedRoute()
                // 启动对账:补建丢失的 sync state,清理指向已删仓库的孤儿引用。
                // 任一持久化文件本次损坏被重置时**必须跳过**:此时空集合不是真实状态,
                // 继续对账会把另外两个健康文件里的关联数据一并清空(级联丢失)。
                if repositoryStore.didRecoverFromCorruptFile || workplaceStore.didRecoverFromCorruptFile {
                    rootSplitViewLog.error(
                        "event=startup_reconcile_skipped reason=corrupt_file_recovered repositories=\(repositoryStore.didRecoverFromCorruptFile, privacy: .public) workplace=\(workplaceStore.didRecoverFromCorruptFile, privacy: .public)"
                    )
                } else {
                    do {
                        try workplaceStore.backfillMissingSyncStates(repositories: repositoryStore.repositories)
                        try workplaceStore.pruneReferencesToRepositories(
                            validRepositoryIDs: Set(repositoryStore.repositories.map(\.id))
                        )
                    } catch {
                        rootSplitViewLog.error("event=startup_reconcile_failed reason=\(error.localizedDescription, privacy: .public)")
                    }
                }
                // 任一持久化文件本次启动曾损坏:必须让用户知道"配置变默认值/记录变少"
                // 不是自己没设置过,且原始文件已保全为 .corrupt- 副本
                // (三个 Store 的 didRecoverFromCorruptFile 消费点,此前只有 settings 有横幅)。
                var corruptedFiles: [String] = []
                if settingsStore.didRecoverFromCorruptFile { corruptedFiles.append("设置") }
                if repositoryStore.didRecoverFromCorruptFile { corruptedFiles.append("仓库配置") }
                if workplaceStore.didRecoverFromCorruptFile { corruptedFiles.append("工作区记录") }
                if corruptedFiles.isEmpty == false {
                    rootSplitViewLog.error(
                        "event=corrupt_recovered_banner files=\(corruptedFiles.joined(separator: ","), privacy: .public)"
                    )
                    var details: [String] = []
                    if settingsStore.didRecoverFromCorruptFile {
                        details.append("工作区根目录、AI 服务等设置回到了初始状态,若有备份文件请重新导入。")
                    }
                    if repositoryStore.didRecoverFromCorruptFile || workplaceStore.didRecoverFromCorruptFile {
                        details.append("已抢救仍可解码的仓库/工作区记录,被丢弃的条目请重新添加。")
                    }
                    details.append("原始文件已保全为应用数据目录下的 .corrupt-<时间戳> 副本;本次启动已跳过自动对账,避免级联清空健康文件里的关联数据。")
                    if corruptedFiles == ["设置"] {
                        details.append("仓库与工作区记录未受影响。")
                    }
                    appearanceFeedback = CCSpaceFeedback(
                        style: .warning,
                        message: "\(corruptedFiles.joined(separator: "、"))文件曾损坏并已恢复",
                        details: details.joined(separator: "\n")
                    )
                }
                scheduleDiskRefresh()
                if shouldShowOnboarding {
                    showOnboarding = true
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                mirroredScenePhase = newPhase
                if newPhase == .active {
                    scheduleDiskRefresh()
                } else {
                    workplaceStore.flushSyncStates()
                    settingsStore.flushSettings()
                }
            }
            // macOS 上 Cmd-Q 不一定先触发 scenePhase 变化,
            // 终止通知里同步 flush,防抖窗口内的终态不丢。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                workplaceStore.flushSyncStates()
                settingsStore.flushSettings()
            }
            .onChange(of: appViewModel.selectedWorkplaceID) { _, _ in
                // 持久化镜像由 AppViewModel 的回调负责(见 bindRoutePersistenceCallbacks,
                // 于 onAppear 注入),这里只清理视图层的动作反馈。
                detailActionCoordinator.feedback = nil
            }
            // 兜底:磁盘刷新也可能静默删除工作区,此时选中项会悬空,
            // 这里在工作区集合变化时校验选中项仍然有效。
            .onChange(of: Set(workplaceStore.workplaces.map(\.id))) { _, currentIDs in
                if let selected = appViewModel.selectedWorkplaceID,
                   !currentIDs.contains(selected) {
                    appViewModel.showRoute(.workplaces)
                }
            }
            // 启动期自动去重是不可撤销的硬删除:此前只写 os_log,用户只会"某次打开
            // 发现仓库少了一个"而无从得知原因。展示与事件解耦(见 DeduplicationNoticeQueue):
            // 1) 观察单调递增的去重序号而非清理条数——onChange 只在值变化时回调,
            //    同启动期两次清理条数相同(2→2)时按条数观察会漏掉第二次;
            // 2) 已有横幅(损坏恢复 .warning 约 3 秒后才消失、.error 需手动关闭)时
            //    不打断,提示入队等横幅空出后补放——此前直接丢弃且事件不会重放。
            .onChange(of: repositoryStore.deduplicationCleanupSequence) { _, _ in
                deduplicationNotices.record(
                    cleanupCount: repositoryStore.lastDeduplicationCleanupCount ?? 0
                )
                presentPendingDeduplicationNotice()
            }
            // 横幅关闭(手动/3 秒自动)后补放入队中的去重提示。
            .onChange(of: appearanceFeedback) { _, newFeedback in
                guard newFeedback == nil else { return }
                presentPendingDeduplicationNotice()
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
            // 外观保存失败等根级操作的可见提示:挂顶层 overlay,任意路由下都能呈现。
            .overlay(alignment: .top) {
                if let shownFeedback = appearanceFeedback {
                    CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { appearanceFeedback = nil })
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.top, 6)
                        .ccspaceAutoDismissFeedback($appearanceFeedback)
                }
            }
    }

    /// 弹层修饰单独成链,同 rootLifecycleModifiers。
    private func rootSheetModifiers(_ content: some View) -> some View {
        content
            .sheet(item: $editingWorkplace) { workplace in
            // sheet item 是打开弹窗那一刻的快照;弹窗打开期间 store 可能已被磁盘刷新
            // 或别处编辑改写。按 id 取实时值,避免拿陈旧快照渲染与比对改动基线。
            let currentWorkplace = workplaceStore.workplaces.first { $0.id == workplace.id } ?? workplace
            WorkplaceEditView(
                workplace: currentWorkplace,
                repositories: repositoryStore.repositories,
                syncStates: workplaceStore.syncStates
            ) { name, selectedRepositoryIDs, branch, progressHandler in
                try await workplaceEditService.saveWorkplaceEdit(
                    workplaceID: workplace.id,
                    name: name,
                    selectedRepositoryIDs: selectedRepositoryIDs,
                    branch: branch,
                    progressHandler: progressHandler
                )
            }
        }
        .sheet(item: $createWorkplaceSheet) { presentation in
            WorkplaceCreateView(
                settingsStore: settingsStore,
                repositoryStore: repositoryStore,
                workplaceCreateService: workplaceCreateService,
                appViewModel: appViewModel,
                initialSeed: presentation.seed,
                onDismiss: {
                    createWorkplaceSheet = nil
                }
            )
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(
                settingsStore: settingsStore,
                repositoryStore: repositoryStore,
                workplaceStore: workplaceStore,
                onComplete: {
                    showOnboarding = false
                }
            )
            .interactiveDismissDisabled()
        }
    }

    private func detailView(for workplace: Workplace) -> some View {
        let filteredSyncStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }
        let actions = WorkplaceDetailActions(
            onEdit: {
                // 动作触发时取最新记录:渲染期快照的心跳刷新滞后,拿它开编辑窗
                // 会展示旧仓库集合,保存时覆盖最新值。
                // 工作区已不在名单(被并发删除)时直接跳过而非用 `?? workplace` 兜底:
                // 编辑入口语义是打开窗口,用旧快照开窗同样会把它落盘覆盖/重建;
                // 侧栏渲染的就是当前行,点击时命中最新记录几乎必然,跳过路径近乎不可达。
                guard let current = latestWorkplace(for: workplace.id) else { return }
                editingWorkplace = current
            },
            onDelete: {
                detailActionCoordinator.run(
                    actionName: "删除工作区"
                ) {
                    // 动作触发时取最新记录:渲染期快照可能已被磁盘刷新改写,
                    // 拿陈旧集合操作会漏处理仓库/路径(与删除仓库路径同一动机)。
                    // 必须 guard 而非 `?? workplace` 兜底:deleteWorkplace 先 rm -rf
                    // 目录后验记录,若工作区已被并发删除且同名重建(新 id),陈旧快照
                    // 会让这里先删掉新目录、再抛 workplaceNotFound——宁可静默不执行,
                    // 也不能拿陈旧快照删盘(同 onDeleteRepository 的写法)。
                    guard let current = latestWorkplace(for: workplace.id) else { return }
                    try await workplaceRuntimeService.deleteWorkplace(
                        current,
                        removeLocalDirectories: true
                    )
                    if appViewModel.selectedWorkplaceID == workplace.id {
                        appViewModel.showRoute(.workplaces)
                    }
                    if editingWorkplace?.id == workplace.id {
                        editingWorkplace = nil
                    }
                }
            },
            onRetry: { repository in
                detailActionCoordinator.run(
                    actionName: "重新克隆仓库",
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.retryClone(
                            repositoryName: repository.repoName,
                            syncState: syncState(
                                workplaceID: workplace.id,
                                repositoryID: repository.id
                            )
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.retryClone(repository: repository, in: current)
                }
            },
            onPullAll: {
                RootSplitWorkplaceActions.runPullRepositories(
                    coordinator: detailActionCoordinator,
                    pullRepositories: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return await workplaceRuntimeService.pullRepositories(in: current)
                    }
                )
            },
            onPush: {
                detailActionCoordinator.run(
                    actionName: "Push 工作区",
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.pushRepositories(in: current)
                    },
                    successFeedback: { result in
                        WorkplaceDetailFeedbackFactory.pushAll(result: result)
                    }
                )
            },
            onPull: { repository in
                detailActionCoordinator.run(
                    actionName: "Pull 仓库",
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return await workplaceRuntimeService.pullRepositories(
                            in: current,
                            repositoryID: repository.id
                        )
                    },
                    successFeedback: { result in
                        let outcome = result.branchSummaries.first?.outcome
                        return WorkplaceDetailFeedbackFactory.syncRepository(
                            repositoryName: repository.repoName,
                            result: result,
                            syncState: syncState(
                                workplaceID: workplace.id,
                                repositoryID: repository.id
                            ),
                            outcome: outcome
                        )
                    }
                )
            },
            onPushRepository: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "Push 仓库",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.pushRepository(
                            for: state,
                            in: current
                        )
                    },
                    successFeedback: { outcome in
                        WorkplaceDetailFeedbackFactory.pushRepository(
                            repositoryName: repositoryName,
                            outcome: outcome,
                            syncState: syncState(
                                workplaceID: workplace.id,
                                repositoryID: state.repositoryID
                            )
                        )
                    }
                )
            },
            onSwitchBranch: { state, repositoryName, branch in
                detailActionCoordinator.run(
                    actionName: "切换分支",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.switchBranch(
                            repositoryName: repositoryName,
                            branch: branch
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.switchBranch(
                        for: state,
                        in: current,
                        to: branch
                    )
                }
            },
            onCreateBranch: { state, repositoryName, branch, base in
                detailActionCoordinator.run(
                    actionName: "新建分支",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.createBranch(
                            repositoryName: repositoryName,
                            branch: branch
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.createBranch(
                        for: state,
                        in: current,
                        to: branch,
                        base: base
                    )
                }
            },
            onDeleteBranch: { state, repositoryName, branch, remoteBranch in
                detailActionCoordinator.run(
                    actionName: "删除分支",
                    refreshBranches: true,
                    successFeedback: {
                        if remoteBranch != nil {
                            return WorkplaceDetailFeedbackFactory.deleteBranchWithRemote(
                                repositoryName: repositoryName,
                                branch: branch
                            )
                        }
                        return WorkplaceDetailFeedbackFactory.deleteBranch(
                            repositoryName: repositoryName,
                            branch: branch
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.deleteBranch(
                        for: state,
                        in: current,
                        branch: branch
                    )
                    // 协调器同一时刻只跑一个动作,远端删除必须挂在同一 operation 内顺序执行。
                    if let remoteBranch {
                        try await workplaceRuntimeService.deleteRemoteBranch(
                            for: state,
                            in: current,
                            branch: remoteBranch
                        )
                    }
                }
            },
            onDeleteRemoteBranch: { state, repositoryName, branch in
                detailActionCoordinator.run(
                    actionName: "删除远端分支",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.deleteRemoteBranch(
                            repositoryName: repositoryName,
                            branch: branch
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.deleteRemoteBranch(
                        for: state,
                        in: current,
                        branch: branch
                    )
                }
            },
            onSwitchRepositoryToDefaultBranch: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "切到默认分支",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.switchRepositoryToDefaultBranch(
                            for: state,
                            in: current
                        )
                    },
                    successFeedback: { defaultBranch in
                        WorkplaceDetailFeedbackFactory.switchRepositoryToDefaultBranch(
                            repositoryName: repositoryName,
                            branch: defaultBranch
                        )
                    }
                )
            },
            onSwitchRepositoryToWorkBranch: { state, repositoryName in
                let workBranch = currentWorkBranch(for: workplace.id)
                detailActionCoordinator.run(
                    actionName: "切到工作分支",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.switchRepositoryToWorkBranch(
                            repositoryName: repositoryName,
                            branch: workBranch
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    _ = try await workplaceRuntimeService.switchRepositoryToWorkBranch(
                        for: state,
                        in: current,
                        workBranch: workBranch
                    )
                }
            },
            onMergeRepositoryDefaultBranchIntoCurrent: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "合并默认分支",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(
                            for: state,
                            in: current
                        )
                    },
                    successFeedback: { outcome in
                        WorkplaceDetailFeedbackFactory.mergeRepositoryDefaultBranchIntoCurrent(
                            repositoryName: repositoryName,
                            outcome: outcome
                        )
                    }
                )
            },
            onCreateMergeRequest: { state, repository, targetBranch in
                RootSplitWorkplaceActions.runCreateMergeRequest(
                    coordinator: detailActionCoordinator,
                    repositoryName: repository.repoName,
                    pushRepository: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        _ = try await workplaceRuntimeService.pushRepository(
                            for: state,
                            in: current
                        )
                    },
                    resolveMergeRequestURL: {
                        try await MergeRequestService.createURL(
                            repository: repository,
                            syncState: state,
                            gitService: gitService,
                            targetBranch: targetBranch
                        )
                    },
                    openInBrowser: { mergeRequestURL in
                        try WorkplaceSystemActions.openInBrowser(mergeRequestURL)
                    }
                )
            },
            onOpenRepositoryWeb: { syncState, repository in
                RootSplitWorkplaceActions.runOpenRepositoryWeb(
                    coordinator: detailActionCoordinator,
                    // 与"创建 MR"同口径:已克隆仓库优先读**实际 origin**——克隆后
                    // 改过远端(如迁 fork)时两个入口不再指向不同仓库;
                    // 读不到(未克隆/无 origin)回退配置的 gitURL。
                    resolveRepositoryURL: {
                        let remote = await gitService.remoteURL(in: syncState.localPath) ?? ""
                        let source = remote.isEmpty ? repository.gitURL : remote
                        return try GitURLParser.repositoryWebURL(from: source)
                    },
                    openInBrowser: { url in
                        try WorkplaceSystemActions.openInBrowser(url)
                    }
                )
            },
            onDeleteRepository: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "删除仓库",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.deleteRepository(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    guard let current = latestWorkplace(for: workplace.id) else { return }
                    try await workplaceEditService.saveWorkplaceEdit(
                        workplaceID: current.id,
                        name: current.name,
                        selectedRepositoryIDs: current.selectedRepositoryIDs.filter {
                            $0 != state.repositoryID
                        },
                        branch: current.branch
                    )
                }
            },
            onTogglePinnedRepository: { state in
                let workplaceID = workplace.id
                let repositoryID = state.repositoryID
                let willPin = !(latestWorkplace(for: workplaceID)?.pinnedRepositoryIDs.contains(repositoryID) ?? false)
                do {
                    try workplaceStore.setRepositoryPinned(
                        willPin,
                        repositoryID: repositoryID,
                        in: workplaceID
                    )
                } catch {
                    setDetailFeedbackIfSelected(
                        WorkplaceDetailFeedbackFactory.actionError(
                            action: willPin ? "置顶仓库" : "取消置顶仓库",
                            error: error
                        ),
                        for: workplaceID
                    )
                }
            },
            onStashChanges: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "Stash 改动",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.stashChanges(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.stashChanges(
                        for: state,
                        in: current
                    )
                }
            },
            onPopStash: { state, entry, repositoryName in
                detailActionCoordinator.run(
                    actionName: "恢复 Stash",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.popStash(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.popStash(
                        entry: entry,
                        for: state,
                        in: current
                    )
                }
            },
            onDropStash: { state, entry, repositoryName in
                detailActionCoordinator.run(
                    actionName: "删除 Stash",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.dropStash(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    let current = latestWorkplace(for: workplace.id) ?? workplace
                    try await workplaceRuntimeService.dropStash(
                        entry: entry,
                        for: state,
                        in: current
                    )
                }
            },
            onAbortInterruptedOperation: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "中止 Git 操作",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.abortInterruptedOperation(
                            for: state,
                            in: current
                        )
                    },
                    successFeedback: { operation in
                        WorkplaceDetailFeedbackFactory.abortInterruptedOperation(
                            repositoryName: repositoryName,
                            operation: operation
                        )
                    }
                )
            },
            onMergeDefaultBranchIntoCurrent: {
                detailActionCoordinator.run(
                    actionName: "合并默认分支",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(in: current)
                    },
                    successFeedback: { result in
                        WorkplaceDetailFeedbackFactory.mergeDefaultBranchIntoCurrent(result: result)
                    }
                )
            },
            onSwitchAllRepositoriesToDefaultBranch: {
                detailActionCoordinator.run(
                    actionName: "批量切到默认分支",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.switchRepositoriesToDefaultBranch(in: current)
                    },
                    successFeedback: { result in
                        WorkplaceDetailFeedbackFactory.switchAllToDefaultBranch(result: result)
                    }
                )
            },
            onSwitchAllRepositoriesToWorkBranch: {
                let workBranch = currentWorkBranch(for: workplace.id)
                detailActionCoordinator.run(
                    actionName: "批量切到工作分支",
                    refreshBranches: true,
                    operation: {
                        let current = latestWorkplace(for: workplace.id) ?? workplace
                        return try await workplaceRuntimeService.switchRepositoriesToWorkBranch(in: current)
                    },
                    successFeedback: { result in
                        WorkplaceDetailFeedbackFactory.switchAllToWorkBranch(
                            branch: workBranch,
                            result: result
                        )
                    }
                )
            },
            onRefreshStatuses: {
                workplaceStore.clearFailedStatusesWhereDirectoryExists(workplaceID: workplace.id)
            },
            onCancelAction: {
                detailActionCoordinator.cancelRunningAction()
            }
        )
        return WorkplaceDetailView(
            workplace: workplace,
            repositories: repositoryStore.repositories,
            syncStates: filteredSyncStates,
            gitService: gitService,
            actions: actions,
            isPerformingAction: detailActionCoordinator.isRunningAction,
            branchRefreshSeed: detailActionCoordinator.branchRefreshSeed,
            feedback: $detailActionCoordinator.feedback,
            installedEditors: openActionsModel.installedEditors,
            installedTerminals: openActionsModel.installedTerminals,
            preferredOpenActionID: settingsStore.settings.preferredOpenActionID,
            onSelectOpenAction: { actionID in
                // 不再用 `try?` 静默吞掉写盘失败:UI 行为不变(仍停在原选择),
                // 但失败必须留痕可查。
                do {
                    try settingsStore.updatePreferredOpenActionID(actionID)
                } catch {
                    rootSplitViewLog.error("event=update_preferred_open_action_failed reason=\(error.localizedDescription, privacy: .public)")
                }
            }
        )
        .id(workplace.id)
    }

    private var emptyWorkplaceState: some View {
        VStack {
            if workplaceStore.workplaces.isEmpty {
                ContentUnavailableView {
                    Label("欢迎使用 CCSpace", systemImage: "sparkles")
                } description: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CCSpace 帮你集中管理多个 Git 仓库，快速切换分支、同步代码。")
                            .multilineTextAlignment(.center)
                        Text("快速开始：")
                            .fontWeight(.medium)
                        VStack(alignment: .leading, spacing: 4) {
                            Label("前往设置，选择工作区根目录", systemImage: "1.circle")
                            Label("添加常用的 Git 仓库地址", systemImage: "2.circle")
                            Label("创建工作区，勾选仓库开始工作", systemImage: "3.circle")
                        }
                        .font(.callout)
                    }
                } actions: {
                    HStack(spacing: 12) {
                        Button("前往设置") {
                            appViewModel.showRoute(.settings)
                        }
                        .ccspaceSecondaryActionButton()
                        Button("创建工作区") {
                            presentCreateWorkplace()
                        }
                        .ccspacePrimaryActionButton()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("选择工作区", systemImage: "folder")
                } description: {
                    Text("从左侧列表选择一个工作区查看详情，或创建新的工作区。")
                } actions: {
                    Button("新建") {
                        presentCreateWorkplace()
                    }
                    .ccspacePrimaryActionButton()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ccspaceScreenBackground()
    }

    /// [设置][AI] tab 栏:挂 principal 位置,标题栏正中,与右上 light/dark 同一行。
    @ToolbarContentBuilder
    private var settingsTabToolbarItem: some ToolbarContent {
        if appViewModel.route == .settings {
            ToolbarItem(placement: .principal) {
                SettingsTabBar(selectedTab: $settingsTab)
            }
        }
    }

    /// 外观切换与"获取更新"合并为同一工具栏 item:
    /// 两个独立 item 之间由系统插入较宽的默认间距,加上"获取更新"组原本的左侧 padding,视觉上隔得过远。
    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if appViewModel.route == .settings {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    // 外观单按钮三态循环:浅色→深色→跟随系统;图标跟随持久化模式。
                    Button {
                        applyAppearanceMode(settingsStore.settings.appearanceMode.nextInCycle)
                    } label: {
                        Image(systemName: settingsStore.settings.appearanceMode.toolbarSystemImage)
                    }
                    .accessibilityLabel(settingsStore.settings.appearanceMode.toolbarButtonTitle)
                    .ccspaceToolbarActionButton(prominent: true)
                    .ccspaceQuickHelp(settingsStore.settings.appearanceMode.toolbarButtonTitle)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button("获取更新 ↗", action: openReleasesPage)
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                            .ccspaceQuickHelp("前往 Releases 下载最新版本")

                        toolbarVersionText
                    }
                    .lineLimit(1)
                    .padding(.trailing, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 生效外观变化(本 App 切换、系统切换、外部重置 NSApp.appearance 均会触发):
    /// 持久化为显式 light/dark 而覆盖被重置时重新应用,自愈"切换不生效"。
    @MainActor
    private func handleEffectiveAppearanceChange() {
        AppearanceModeApplier.reconcileOverride(with: settingsStore.settings.appearanceMode)
    }

    /// 应用外观分段选择:持久化 + 立即生效。在按钮动作上下文执行,
    /// 避免渲染期修改 NSApp.appearance(表现为闪两次、需再次交互才恢复)。
    @MainActor
    private func applyAppearanceMode(_ mode: AppSettings.AppearanceMode) {
        do {
            try settingsStore.updateAppearanceMode(mode)
            AppearanceModeApplier.apply(mode)
        } catch {
            // 保存失败时保持现状,下次启动仍为原外观;
            // 不再静默吞掉:记日志并给用户可见提示。
            rootSplitViewLog.error(
                "持久化外观模式 \(mode.rawValue, privacy: .public) 失败: \(error.localizedDescription, privacy: .public)"
            )
            appearanceFeedback = CCSpaceFeedbackFactory.actionError(
                action: "保存外观设置",
                error: error
            )
        }
    }

    @ViewBuilder
    private var toolbarVersionText: some View {
        HStack(spacing: 6) {
            if updatePresentationState.showsUpdateAvailable,
               let latestVersionDisplay = updatePresentationState.latestVersionDisplay {
                Text(updatePresentationState.currentVersionDisplay)
                    .strikethrough()
                    .foregroundStyle(.tertiary)
                Text(latestVersionDisplay)
                    .foregroundStyle(.orange)
            } else {
                Text(updatePresentationState.currentVersionDisplay)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    private func openReleasesPage() {
        NSWorkspace.shared.open(updateChecker.releasesURL)
    }

    @MainActor
    private func presentCreateWorkplace(seed: WorkplaceCreateSeed = .empty) {
        createWorkplaceSheet = WorkplaceCreateSheetPresentation(seed: seed)
    }

    @MainActor
    private func duplicateWorkplace(_ workplace: Workplace) {
        let existingNames = workplaceStore.workplaces.map(\.name)
        presentCreateWorkplace(seed: .duplicate(from: workplace, existingNames: existingNames))
    }

    @MainActor
    private func togglePinned(for workplace: Workplace) {
        let willPin = !workplace.isPinned
        // 归档分组忽略置顶排序,置顶已归档工作区需先取消归档,否则置顶不生效。
        let shouldUnarchive = willPin && workplace.isArchived
        do {
            try workplaceStore.setPinned(willPin, for: workplace.id)
            if shouldUnarchive {
                try workplaceStore.setArchived(false, for: workplace.id)
            }
            setDetailFeedbackIfSelected(
                CCSpaceFeedbackFactory.actionSuccess(
                    shouldUnarchive
                        ? "已取消归档并置顶 \(workplace.name)"
                        : willPin ? "已置顶 \(workplace.name)" : "已取消置顶 \(workplace.name)"
                ),
                for: workplace.id
            )
        } catch {
            setDetailFeedbackIfSelected(
                CCSpaceFeedbackFactory.actionError(
                    action: willPin ? "置顶工作区" : "取消置顶工作区",
                    error: error
                ),
                for: workplace.id
            )
        }
    }

    @MainActor
    private func toggleArchived(for workplace: Workplace) {
        let willArchive = !workplace.isArchived
        // 归档分组忽略置顶排序,归档置顶工作区需先取消置顶,避免归档期间残留置顶状态。
        let shouldUnpin = willArchive && workplace.isPinned
        do {
            if shouldUnpin {
                try workplaceStore.setPinned(false, for: workplace.id)
            }
            try workplaceStore.setArchived(willArchive, for: workplace.id)
            setDetailFeedbackIfSelected(
                CCSpaceFeedbackFactory.actionSuccess(
                    shouldUnpin
                        ? "已取消置顶并归档 \(workplace.name)"
                        : willArchive ? "已归档 \(workplace.name)" : "已取消归档 \(workplace.name)"
                ),
                for: workplace.id
            )
        } catch {
            setDetailFeedbackIfSelected(
                CCSpaceFeedbackFactory.actionError(
                    action: willArchive ? "归档工作区" : "取消归档工作区",
                    error: error
                ),
                for: workplace.id
            )
        }
    }

    @MainActor
    private func setDetailFeedbackIfSelected(
        _ feedback: CCSpaceFeedback,
        for workplaceID: UUID
    ) {
        guard appViewModel.selectedWorkplaceID == workplaceID else {
            // 从侧栏对"未选中"的工作区操作(置顶/归档等)时,详情区的反馈通道不在
            // 当前屏上——此前直接 return,失败与成功提示双双被吞。错误改走根级
            // overlay 横幅(任意路由可见);成功提示同样上抛,避免"点了没反应"。
            appearanceFeedback = feedback
            return
        }
        detailActionCoordinator.feedback = feedback
    }

    /// 出队待展示的去重清理提示;横幅被占用时原地保留,等横幅关闭后由
    /// `.onChange(of: appearanceFeedback)` 再次进入本方法。
    @MainActor
    private func presentPendingDeduplicationNotice() {
        guard let feedback = deduplicationNotices.presentIfIdle(currentBanner: appearanceFeedback) else {
            return
        }
        appearanceFeedback = feedback
    }

    private func latestWorkplace(for id: UUID) -> Workplace? {
        workplaceStore.workplaces.first { $0.id == id }
    }

    /// 取工作区当前配置的工作分支(去首尾空白);未配置时返回空串。
    /// 单个/批量"切到工作分支"两个入口共用,避免裁剪逻辑两处漂移。
    private func currentWorkBranch(for workplaceID: UUID) -> String {
        latestWorkplace(for: workplaceID)?.branch?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func syncState(
        workplaceID: UUID,
        repositoryID: UUID
    ) -> RepositorySyncState? {
        workplaceStore.syncStates.first {
            $0.workplaceID == workplaceID && $0.repositoryID == repositoryID
        }
    }

    @MainActor
    private func applyLaunchConfigurationIfNeeded() {
        guard hasAppliedLaunchConfiguration == false else { return }
        hasAppliedLaunchConfiguration = true

        guard let screenshotScene = launchConfiguration.screenshotScene else {
            return
        }

        switch screenshotScene {
        case .settingsOverview:
            appViewModel.showRoute(.settings)
            createWorkplaceSheet = nil
        case .workplaceDetail:
            if let workplace = launchConfiguration.targetWorkplace(
                in: workplaceStore.workplaces
            ) {
                appViewModel.showWorkplace(workplace.id)
            } else {
                appViewModel.showRoute(.workplaces)
            }
            createWorkplaceSheet = nil
        case .createWorkplace:
            if let workplace = launchConfiguration.targetWorkplace(
                in: workplaceStore.workplaces
            ) {
                appViewModel.showWorkplace(workplace.id)
            } else {
                appViewModel.showRoute(.workplaces)
            }
            presentCreateWorkplace(
                seed: launchConfiguration.createWorkplaceSeed(
                    repositories: repositoryStore.repositories
                )
            )
        }
    }

    /// 注入路由持久化回调:AppViewModel 是路由的唯一事实来源,写 settings.json
    /// 镜像由其内部触发,View 修饰链不承担持久化职责。
    /// 必须在 onAppear 绑定而不是 init:init 里拿不到 SwiftUI 实际持有的
    /// SettingsStore(它还在 StateObject 的 autoclosure 里惰性构造),提前构造
    /// 实例正是要消灭的"每次视图重建都同步读盘再丢弃";onAppear 时 body 已求值,
    /// 此处读到的就是同一个实例。
    @MainActor
    private func bindRoutePersistenceCallbacks() {
        let settingsStore = self.settingsStore
        appViewModel.onRouteChange = { settingsStore.updateLastSelectedRoute($0.rawValue) }
        appViewModel.onSelectedWorkplaceChange = { settingsStore.updateLastSelectedWorkplaceID($0?.uuidString) }
    }

    @MainActor
    private func restoreLastSelectedRoute() {
        // 截图模式下 applyLaunchConfigurationIfNeeded 已指定目标路由,
        // 恢复上次选中会把它覆盖掉(截图场景拍成上次退出时的页面),直接跳过。
        guard launchConfiguration.screenshotScene == nil else { return }
        let settings = settingsStore.settings
        // 经 AppRoute(rawValue:) 校验而非裸字符串比较:
        // 持久化值可能来自旧版本/手改文件,非法值直接忽略,落到默认路由。
        // 上次在工作区页但选中项缺失/非法/工作区已删时,降级到"工作区列表"
        // 而不是什么都不做——否则会落回默认 .settings,与用户上次所在页面无关。
        guard let selection = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: settings.lastSelectedRoute,
            lastSelectedWorkplaceID: settings.lastSelectedWorkplaceID,
            workplaces: workplaceStore.workplaces
        ) else { return }
        // 分支接线收在 RouteRestoreSupport.apply(可测):降级到列表页只切路由,
        // 不得把 nil 写回 lastSelectedWorkplaceID——旧版本在此分支什么都不做。
        // 选中项缺失/非法/已删往往正是本轮 workplaces.json 被损坏重置的结果,
        // 再把 nil 落盘等于单点损坏级联改写另一份健康数据;真正的删除由运行期删除路径持久化。
        RouteRestoreSupport.apply(selection, to: appViewModel)
    }

    @MainActor
    private func scheduleDiskRefresh() {
        let refreshState = RootSplitDiskRefreshState(
            route: appViewModel.route,
            selectedWorkplaceID: appViewModel.selectedWorkplaceID,
            scenePhase: mirroredScenePhase,
            rootPath: settingsStore.settings.workplaceRootPath
        )

        guard refreshTask == nil else { return }
        guard refreshState.canScheduleRefresh else { return }

        let shouldInvalidateBranches = refreshState.shouldInvalidateBranchesAfterRefresh
        let rootPath = refreshState.normalizedRootPath
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task {
            await diskRefreshService.refresh(rootPath: rootPath)
            let isCurrentGeneration = refreshGeneration == generation
            if isCurrentGeneration {
                refreshTask = nil
                // 被取消的旧任务绝不能触碰句柄与分支缓存:它返回时新任务可能正在跑,
                // 清句柄会导致下一轮调度与前一轮并发。
                if Task.isCancelled == false, shouldInvalidateBranches {
                    detailActionCoordinator.invalidateBranches()
                }
            }
        }
    }

    /// 每小时检查一次更新;仅 App 处于活跃状态时执行。
    /// Task 取消(视图消失)时 sleep 抛错退出循环。
    /// 读 mirroredScenePhase(@State)而非 @Environment:后者的值在长驻闭包里是首帧快照。
    private func runPeriodicUpdateCheck() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                return // 任务被取消(视图销毁),退出循环
            }
            guard mirroredScenePhase == .active else { continue }
            await updateChecker.check()
        }
    }

    /// 每 120 秒做一次磁盘刷新,并周期重检编辑器/终端,
    /// 新安装的 App 无需重启即可出现在"打开方式"菜单。
    private func runPeriodicDiskRefresh() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                return // 任务被取消(视图销毁),退出循环
            }
            scheduleDiskRefresh()
            openActionsModel.refresh()
        }
    }
}
