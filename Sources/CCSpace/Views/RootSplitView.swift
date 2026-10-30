import AppKit
import os
import SwiftUI

private let rootSplitViewLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RootSplitView"
)

struct RootSplitView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// scenePhase 的 @State 镜像:长驻 `.task` 闭包捕获首帧视图拷贝,@Environment 的值在拷贝上冻结;
    /// @State 走外部存储,任何时刻读到的都是当前值(onAppear/onChange 双点同步)。
    @State private var mirroredScenePhase: ScenePhase = .active
    /// 磁盘刷新世代号:被取消的旧任务晚于新任务返回时无条件清 refreshTask,会抹掉**新任务**的句柄,
    /// 后续调度 guard 放行、并发磁盘刷新。
    @State private var refreshGeneration: UInt64 = 0
    @State private var isInFlightDiskRefreshForced = false
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
    @State private var appearanceFeedback: CCSpaceFeedback?
    @State private var deduplicationNotices = DeduplicationNoticeQueue()
    /// 详情页分支快照的进程内缓存:随 `.id(workplace.id)` 销毁的 @State 会让每次切换重跑全量 git 扫描。
    @State private var branchSnapshotCache = WorkplaceBranchSnapshotCache()
    private let launchConfiguration: CCSpaceLaunchConfiguration
    private let syncCoordinator: SyncCoordinator
    private let gitService: GitService
    /// 仓库只读信息查询(实际 origin 等)由顶层注入,View 侧不直接调 git(AGENTS.md 分层规则)。
    private let repositoryInfoService: RepositoryInfoService

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
        WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: syncCoordinator,
            workplaceRootPath: settingsStore.settings.workplaceRootPath
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

    private var updateButtonState: UpdateButtonPresentationState {
        UpdateButtonPresentationState(updatePresentationState: updatePresentationState)
    }

    private var diskRefreshService: DiskRefreshService {
        DiskRefreshService(
            workplaceStore: workplaceStore,
            repositoryStore: repositoryStore,
            gitService: gitService
        )
    }

    init(
        launchConfiguration: CCSpaceLaunchConfiguration = CCSpaceLaunchConfiguration(),
        gitService: GitService = GitService()
    ) {
        self.launchConfiguration = launchConfiguration

        let fileStore = JSONFileStore(
            rootDirectory: launchConfiguration.resolvedAppSupportDirectory()
        )
        // 三个 Store 必须在 StateObject(wrappedValue:) 的 autoclosure 内惰性构造:先 `let instance = Store(...)`
        // 再塞进去会让延迟语义失效,视图结构体每次重建都同步读盘(损坏文件还触发 preserveCorruptFile 副作用)而实例随即被丢弃。
        _settingsStore = StateObject(wrappedValue: SettingsStore(fileStore: fileStore))
        _repositoryStore = StateObject(wrappedValue: RepositoryStore(fileStore: fileStore))
        _workplaceStore = StateObject(wrappedValue: WorkplaceStore(fileStore: fileStore))
        self.gitService = gitService
        self.repositoryInfoService = RepositoryInfoService(gitService: gitService)
        syncCoordinator = SyncCoordinator(gitService: gitService)

        let appViewModel = AppViewModel()
        _appViewModel = StateObject(wrappedValue: appViewModel)

        // 首帧外观:直接读盘一次并应用(仅进程内第一次构造执行)。不能读 _settingsStore.wrappedValue——那会强制求值
        // autoclosure,视图每次重建都新造一个 SettingsStore 又丢弃(白白同步读盘);onAppear 的 reconcileOverride 兜底后续变更。
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

    /// 首帧外观标记。View 构造总在主线程,但编译器无法证明,须经 assumeIsolated 声明后才能触达 @MainActor 存储。
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
                            showOnboarding: $showOnboarding
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
                    settingsToolbarItem
                }
                .navigationSplitViewStyle(.balanced)
                .frame(minWidth: 680, minHeight: 480)
            )
        )
    }

    /// 生命周期/定时刷新修饰单独成链:body 单条修饰链过长会触发类型检查超时。
    private func rootLifecycleModifiers(_ content: some View) -> some View {
        content
            // 截图场景关掉悬停气泡:指针恰好停在某个控件上时,气泡会跟着一起被截进 README 图。
            .environment(\.ccspaceQuickHelpEnabled, launchConfiguration.screenshotScene == nil)
            .task {
                await updateChecker.check()
            }
            // 周期任务用 .task 长循环驱动;Timer.publish 写在 body 修饰链里会随每次渲染重建、
            // 倒计时反复归零,周期任务事实失效。
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
                detailActionCoordinator.selectedWorkplaceIDProvider = { [appViewModel] in
                    appViewModel.selectedWorkplaceID
                }
                // 路由持久化回调必须先于下面任何会改路由的动作(否则首个回调找不到落点)。
                bindRoutePersistenceCallbacks()
                AppearanceModeApplier.reconcileOverride(with: settingsStore.settings.appearanceMode)
                applyLaunchConfigurationIfNeeded()
                restoreLastSelectedRoute()
                // 启动对账:补建丢失的 sync state、清理指向已删仓库的孤儿引用。任一持久化文件本次
                // 损坏被重置时**必须跳过**:空集合不是真实状态,继续对账会级联清空另外两个健康文件的关联数据。
                if repositoryStore.didRecoverFromCorruptFile
                    || workplaceStore.didRecoverFromCorruptFile {
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
                // 任一持久化文件本次启动曾损坏:必须让用户知道"配置变默认值/记录变少"的缘由,
                // 且原始文件已保全为 .corrupt- 副本(各 Store 的 didRecoverFromCorruptFile 消费点)。
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
                        details.append("工作区根目录等设置回到了初始状态,若有备份文件请重新导入。")
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
            // 关窗在 macOS 上不等于退出进程:store 随视图释放,防抖里尚未落盘的终态会一起丢掉。
            .onDisappear {
                workplaceStore.flushSyncStates()
                settingsStore.flushSettings()
            }
            .onChange(of: appViewModel.selectedWorkplaceID) { _, _ in
                // @Published 不做同值守卫:nil → nil 也会发一次变更、整棵分栏树多渲染一轮,
                // 而"选中项变化时本来就没有反馈"是这条链路的常态。
                if detailActionCoordinator.feedback != nil {
                    detailActionCoordinator.feedback = nil
                }
            }
            // 兜底:磁盘刷新也可能静默删除工作区,此时选中项悬空,在集合变化时校验选中项仍有效。
            .onChange(of: Set(workplaceStore.workplaces.map(\.id))) { _, currentIDs in
                if let selected = appViewModel.selectedWorkplaceID,
                   !currentIDs.contains(selected) {
                    appViewModel.showRoute(.workplaces)
                }
            }
            // 去重是不可撤销的硬删除,提示必须送达。这里观察单调递增的去重序号而非清理条数:
            // onChange 只在值变化时回调,同启动期两次清理条数相同(2→2)时按条数观察会漏掉第二次。
            .onChange(of: repositoryStore.deduplicationCleanupSequence) { _, _ in
                deduplicationNotices.record(
                    cleanupCount: repositoryStore.lastDeduplicationCleanupCount ?? 0
                )
                presentPendingDeduplicationNotice()
            }
            .onChange(of: appearanceFeedback) { _, newFeedback in
                guard newFeedback == nil else { return }
                presentPendingDeduplicationNotice()
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
                isInFlightDiskRefreshForced = false
            }
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
            // sheet item 是打开弹窗那一刻的快照,期间 store 可能已被磁盘刷新或别处编辑改写;
            // 按 id 取实时值,避免拿陈旧快照渲染与比对改动基线。
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
                // 动作触发时取最新记录:渲染期快照滞后,拿它开编辑窗会展示旧仓库集合并在保存时覆盖最新值。
                // 工作区已不在名单(被并发删除)时跳过而非 `?? workplace` 兜底:旧快照同样会落盘覆盖/重建。
                guard let current = latestWorkplace(for: workplace.id) else { return }
                editingWorkplace = current
            },
            onDelete: {
                detailActionCoordinator.run(
                    actionName: "删除工作区"
                ) {
                    // 必须 guard 而非 `?? workplace` 兜底:deleteWorkplace 先 rm -rf 目录后验记录,
                    // 陈旧快照会先删掉同名重建的新目录——宁可静默不执行,也不能拿陈旧快照删盘。
                    guard let current = latestWorkplace(for: workplace.id) else { return }
                    try await workplaceRuntimeService.deleteWorkplace(
                        current,
                        removeLocalDirectories: true
                    )
                    branchSnapshotCache.invalidate(workplace.id)
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
            onCreateMergeRequestForBranch: { state, repository, targetBranch in
                RootSplitWorkplaceActions.runCreateMergeRequestForBranch(
                    coordinator: detailActionCoordinator,
                    repositoryName: repository.repoName,
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
                    // 与"创建 MR"同口径:已克隆优先读**实际 origin**(克隆后改过远端时两个入口不再指向不同仓库),
                    // 读不到(未克隆/无 origin)回退配置的 gitURL。
                    resolveRepositoryURL: {
                        let remote = await repositoryInfoService.remoteURL(
                            localPath: syncState.localPath
                        ) ?? ""
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
            onDiskRefresh: {
                scheduleDiskRefresh(force: true)
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
            branchSnapshotCache: branchSnapshotCache,
            onSelectOpenAction: { actionID in
                // 不用 `try?` 静默吞掉写盘失败:UI 行为不变(仍停在原选择),但失败必须留痕可查。
                do {
                    try settingsStore.updatePreferredOpenActionID(actionID)
                } catch {
                    rootSplitViewLog.error("event=update_preferred_open_action_failed reason=\(error.localizedDescription, privacy: .public)")
                }
            }
        )
        .environment(\.ccspaceScreenshotBranchRepo, launchConfiguration.branchPanelRepositoryName)
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

    /// 外观切换与"获取更新"合并为同一工具栏 item:
    /// 两个独立 item 之间由系统插入较宽的默认间距,加上"获取更新"组原本的左侧 padding,视觉上隔得过远。
    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if appViewModel.route == .settings {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        applyAppearanceMode(settingsStore.settings.appearanceMode.nextInCycle)
                    } label: {
                        Image(systemName: settingsStore.settings.appearanceMode.toolbarSystemImage)
                    }
                    .accessibilityLabel(settingsStore.settings.appearanceMode.toolbarButtonTitle)
                    .ccspaceToolbarActionButton()
                    .ccspaceQuickHelp(settingsStore.settings.appearanceMode.toolbarButtonTitle)

                    // 图标没有文字基线,整行按 .center 对齐:标识与 13pt 版本号文字自然居中,不需要为字号变化维护魔法偏移。
                    HStack(alignment: .center, spacing: 6) {
                        Button(action: openReleasesPage) {
                            GitHubMarkShape()
                                .fill(updateButtonState.usesAccentTint ? Color.accentColor : Color.primary)
                                .frame(width: 15, height: 15)
                                // Shape 的默认命中区只覆盖墨迹,标识外圈留白(圆角四角、尾巴细线之间)点击会落空;
                                // 撑成 23×23 矩形命中区,与文字的实际间距仍是原来的 10pt。
                                .frame(width: 23, height: 23)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // 图标按钮无可见文字,靠 providesLabel 挂成无障碍名称;传 true 后 QuickHelp 去重,不会 label/hint 各读一遍。
                        .ccspaceQuickHelp(updateButtonState.title, providesLabel: true)

                        toolbarVersionText
                    }
                    .lineLimit(1)
                    .padding(.trailing, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @MainActor
    private func handleEffectiveAppearanceChange() {
        AppearanceModeApplier.reconcileOverride(with: settingsStore.settings.appearanceMode)
    }

    /// 持久化 + 立即生效。必须在按钮动作上下文执行:渲染期修改 NSApp.appearance 会闪两次、需再次交互才恢复。
    @MainActor
    private func applyAppearanceMode(_ mode: AppSettings.AppearanceMode) {
        do {
            try settingsStore.updateAppearanceMode(mode)
            AppearanceModeApplier.apply(mode)
        } catch {
            // 保存失败时保持现状,下次启动仍为原外观;记日志并给用户可见提示。
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
        // open 返回 false 与命中区落空表现相同,无法区分,故给出可见提示并附上可手动访问的地址。
        if !NSWorkspace.shared.open(updateChecker.releasesURL) {
            appearanceFeedback = CCSpaceFeedback(
                style: .error,
                message: "打开 GitHub Releases 失败",
                details: "请检查系统默认浏览器设置，或手动访问 \(updateChecker.releasesURL.absoluteString)"
            )
        }
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
            // 侧栏对"未选中"工作区操作时详情区反馈不在当前屏上,改走根级 overlay 横幅(任意路由可见)。
            appearanceFeedback = feedback
            return
        }
        detailActionCoordinator.feedback = feedback
    }

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
            // 设置页打开时 AppKit 会把首个可编辑控件(地址框)设成第一响应者,光标闪烁让截图
            // 稳定采样永远等不到连续一致的帧。只在截图场景下延迟清掉,正常使用不受影响。
            scheduleScreenshotFocusReset()
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

        // 路由切完再定尺:窗口此刻才真正存在,早一帧拿到的是旧 frame 或被 SwiftUI 覆写。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            resizeScreenshotWindowIfNeeded()
        }
    }

    @MainActor
    private func scheduleScreenshotFocusReset() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            let window = NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
            window?.makeFirstResponder(nil)
        }
    }

    /// 截图场景显式定尺:`.defaultSize` 只在"没有存档 frame"时生效,而 SwiftUI 会把窗口 frame
    /// 写进偏好(`NSWindow Frame …`),实测三个场景拿到的都是恢复来的尺寸,脚本传的
    /// `CCSPACE_WINDOW_SIZE` 一直是空转——详情页要把分支面板往下摊开,没有这块高度就必然翻到上方压住列表。
    @MainActor
    private func resizeScreenshotWindowIfNeeded() {
        guard launchConfiguration.screenshotScene != nil else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
        window.setContentSize(
            NSSize(
                width: launchConfiguration.windowSize.width,
                height: launchConfiguration.windowSize.height
            )
        )
        window.center()
    }

    /// 路由持久化回调必须在 onAppear 而不是 init 绑定:init 拿不到 SwiftUI 实际持有的 SettingsStore
    /// (还在 StateObject autoclosure 里),提前构造正是要消灭的"每次视图重建都同步读盘再丢弃";onAppear 时 body 已求值。
    @MainActor
    private func bindRoutePersistenceCallbacks() {
        let settingsStore = self.settingsStore
        appViewModel.onRouteChange = { settingsStore.updateLastSelectedRoute($0.rawValue) }
        appViewModel.onSelectedWorkplaceChange = { settingsStore.updateLastSelectedWorkplaceID($0?.uuidString) }
    }

    @MainActor
    private func restoreLastSelectedRoute() {
        // 截图模式下 applyLaunchConfigurationIfNeeded 已指定目标路由,恢复上次选中会把它覆盖掉。
        guard launchConfiguration.screenshotScene == nil else { return }
        let settings = settingsStore.settings
        guard let selection = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: settings.lastSelectedRoute,
            lastSelectedWorkplaceID: settings.lastSelectedWorkplaceID,
            workplaces: workplaceStore.workplaces
        ) else { return }
        // 降级到列表页只切路由,不得把 nil 回写 lastSelectedWorkplaceID(接线收在 RouteRestoreSupport.apply):
        // 选中项非法往往正是本轮 workplaces.json 被损坏重置的结果,再落盘等于级联改写另一份健康数据。
        RouteRestoreSupport.apply(selection, to: appViewModel)
    }

    @MainActor
    private func scheduleDiskRefresh(force: Bool = false) {
        let refreshState = RootSplitDiskRefreshState(
            route: appViewModel.route,
            selectedWorkplaceID: appViewModel.selectedWorkplaceID,
            scenePhase: mirroredScenePhase,
            rootPath: settingsStore.settings.workplaceRootPath,
            force: force,
            hasForcedRefreshInFlight: isInFlightDiskRefreshForced
        )

        if refreshState.shouldTakeOverInFlightRefresh {
            refreshTask?.cancel()
            refreshTask = nil
        } else {
            guard refreshTask == nil else { return }
        }
        guard refreshState.canScheduleRefresh else { return }

        let shouldInvalidateBranches = refreshState.shouldInvalidateBranchesAfterRefresh
        let rootPath = refreshState.normalizedRootPath
        refreshGeneration += 1
        let generation = refreshGeneration
        isInFlightDiskRefreshForced = force
        // 接手式取消只是把旧任务推进取消状态:它多半正逐候选跑 ls-remote(秒级),要等回到下一个 `Task.isCancelled`
        // 检查点才退出并 defer 释放 DiskRefreshService 的单飞闸门;新任务抢跑会 gate.begin 失败、静默返回 0 个纳入。
        let previousTask = refreshTask
        refreshTask = Task {
            await previousTask?.value
            let outcome = await diskRefreshService.refresh(rootPath: rootPath)
            let isCurrentGeneration = refreshGeneration == generation
            if isCurrentGeneration {
                refreshTask = nil
                isInFlightDiskRefreshForced = false
                // 反馈同样只在当前代发布:被取代的旧任务会绕过归属检查,把过期消息盖到唯一槽位上。
                if outcome.importedRepositoryCount > 0 {
                    // 仓库是"自己冒出来"的,不给提示用户只会看到一个没配过的仓库出现在列表里。
                    appearanceFeedback = CCSpaceFeedbackFactory.actionSuccess(
                        "已自动纳入 \(outcome.importedRepositoryCount) 个拷入工作区目录的 Git 仓库"
                    )
                }
                // 被取消的旧任务不得触碰分支缓存:它返回时新任务可能正在跑。
                if Task.isCancelled == false, shouldInvalidateBranches {
                    detailActionCoordinator.invalidateBranches()
                }
            }
        }
    }

    /// 每小时检查一次更新,仅 App 活跃时执行;Task 取消(视图消失)时 sleep 抛错退出循环。
    private func runPeriodicUpdateCheck() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                return
            }
            guard mirroredScenePhase == .active else { continue }
            await updateChecker.check()
        }
    }

    /// 每 120 秒磁盘刷新,并周期重检编辑器/终端——新装的 App 无需重启即出现在"打开方式"菜单。
    private func runPeriodicDiskRefresh() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                return
            }
            scheduleDiskRefresh()
            // 退到后台不必重扫 /Applications:兄弟周期任务同样按 scenePhase 收口,
            // 回前台后最多 120s 内会补上一次。
            guard mirroredScenePhase == .active else { continue }
            openActionsModel.refresh()
        }
    }
}
