import os
import SwiftUI

private let rootSplitViewLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RootSplitView"
)

struct RootSplitView: View {
    @Environment(\.scenePhase) private var scenePhase
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
        _settingsStore = StateObject(wrappedValue: SettingsStore(fileStore: fileStore))
        _repositoryStore = StateObject(wrappedValue: RepositoryStore(fileStore: fileStore))
        _workplaceStore = StateObject(wrappedValue: WorkplaceStore(fileStore: fileStore))
        self.gitService = gitService
        self.aiService = aiService
        syncCoordinator = SyncCoordinator(gitService: gitService)
        // 首帧外观:直接读盘一次并应用(仅进程内第一次构造执行)。
        // 不能读 _settingsStore.wrappedValue——那会强制求值 autoclosure,
        // 视图结构体每次重建都新造一个 SettingsStore 又丢弃(白白同步读盘,
        // 且 corrupt 文件还会触发 preserveCorruptFile 副作用)。
        // onAppear 里的 reconcileOverride 兜底后续变更与 SwiftUI 实际持有的实例。
        if Self.hasAppliedLaunchAppearance == false {
            Self.hasAppliedLaunchAppearance = true
            let persistedMode = (try? fileStore.loadIfPresent(
                AppSettings.self,
                from: "settings.json",
                default: AppSettings(workplaceRootPath: "")
            ))?.appearanceMode ?? .system
            AppearanceModeApplier.reconcileOverride(with: persistedMode)
        }
    }

    /// 首帧外观只应用一次;init 均在主线程执行,无并发写。
    nonisolated(unsafe) private static var hasAppliedLaunchAppearance = false

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
                // 启动恢复持久化的外观;覆盖若已被外部清空(显式模式下即不一致)会在此重新应用。
                AppearanceModeApplier.reconcileOverride(with: settingsStore.settings.appearanceMode)
                applyLaunchConfigurationIfNeeded()
                restoreLastSelectedRoute()
                // 启动对账:补建丢失的 sync state,清理指向已删仓库的孤儿引用。
                // 任一持久化文件本次损坏被重置时**必须跳过**:此时空集合不是真实状态,
                // 继续对账会把另外两个健康文件里的关联数据一并清空(级联丢失)。
                if repositoryStore.didRecoverFromCorruptFile || workplaceStore.didRecoverFromCorruptFile {
                    rootSplitViewLog.error(
                        "event=startup_reconcile_skipped reason=corrupt_file_recovered repositories=\(repositoryStore.didRecoverFromCorruptFile) workplace=\(workplaceStore.didRecoverFromCorruptFile)"
                    )
                } else {
                    do {
                        try workplaceStore.backfillMissingSyncStates(repositories: repositoryStore.repositories)
                        try workplaceStore.pruneReferencesToRepositories(
                            validRepositoryIDs: Set(repositoryStore.repositories.map(\.id))
                        )
                    } catch {
                        rootSplitViewLog.error("event=startup_reconcile_failed reason=\(error.localizedDescription)")
                    }
                }
                scheduleDiskRefresh()
                if shouldShowOnboarding {
                    showOnboarding = true
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
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
            .onChange(of: appViewModel.selectedWorkplaceID) { _, newID in
                detailActionCoordinator.feedback = nil
                settingsStore.updateLastSelectedWorkplaceID(newID?.uuidString)
            }
            .onChange(of: appViewModel.route) { _, newRoute in
                settingsStore.updateLastSelectedRoute(newRoute.rawValue)
            }
            // 兜底:磁盘刷新(refreshFromDisk)也可能静默删除工作区,此时选中项会悬空,
            // 这里在工作区集合变化时校验选中项仍然有效。
            .onChange(of: Set(workplaceStore.workplaces.map(\.id))) { _, currentIDs in
                if let selected = appViewModel.selectedWorkplaceID,
                   !currentIDs.contains(selected) {
                    appViewModel.showRoute(.workplaces)
                }
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
            // 外观保存失败等根级操作的可见提示:挂顶层 overlay,任意路由下都能呈现。
            .overlay(alignment: .top) {
                if let appearanceFeedback {
                    CCSpaceFeedbackBanner(feedback: appearanceFeedback)
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
                editingWorkplace = workplace
            },
            onDelete: {
                detailActionCoordinator.run(
                    actionName: "删除工作区"
                ) {
                    try await workplaceRuntimeService.deleteWorkplace(
                        workplace,
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
                    try await workplaceRuntimeService.retryClone(repository: repository, in: workplace)
                }
            },
            onPullAll: {
                RootSplitWorkplaceActions.runPullRepositories(
                    coordinator: detailActionCoordinator,
                    pullRepositories: {
                        await workplaceRuntimeService.pullRepositories(in: workplace)
                    }
                )
            },
            onPush: {
                detailActionCoordinator.run(
                    actionName: "Push 工作区",
                    operation: {
                        try await workplaceRuntimeService.pushRepositories(in: workplace)
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
                        await workplaceRuntimeService.pullRepositories(
                            in: workplace,
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
                        try await workplaceRuntimeService.pushRepository(
                            for: state,
                            in: workplace
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
                    try await workplaceRuntimeService.switchBranch(
                        for: state,
                        in: workplace,
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
                    try await workplaceRuntimeService.createBranch(
                        for: state,
                        in: workplace,
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
                    try await workplaceRuntimeService.deleteBranch(
                        for: state,
                        in: workplace,
                        branch: branch
                    )
                    // 协调器同一时刻只跑一个动作,远端删除必须挂在同一 operation 内顺序执行。
                    if let remoteBranch {
                        try await workplaceRuntimeService.deleteRemoteBranch(
                            for: state,
                            in: workplace,
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
                    try await workplaceRuntimeService.deleteRemoteBranch(
                        for: state,
                        in: workplace,
                        branch: branch
                    )
                }
            },
            onSwitchRepositoryToDefaultBranch: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "切到默认分支",
                    refreshBranches: true,
                    operation: {
                        try await workplaceRuntimeService.switchRepositoryToDefaultBranch(
                            for: state,
                            in: workplace
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
                let workBranch = latestWorkplace(for: workplace.id)?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                    _ = try await workplaceRuntimeService.switchRepositoryToWorkBranch(
                        for: state,
                        in: workplace,
                        workBranch: workBranch
                    )
                }
            },
            onMergeRepositoryDefaultBranchIntoCurrent: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "合并默认分支",
                    refreshBranches: true,
                    operation: {
                        try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(
                            for: state,
                            in: workplace
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
                        _ = try await workplaceRuntimeService.pushRepository(
                            for: state,
                            in: workplace
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
                    try await workplaceRuntimeService.stashChanges(
                        for: state,
                        in: workplace
                    )
                }
            },
            onPopStash: { state, index, repositoryName in
                detailActionCoordinator.run(
                    actionName: "恢复 Stash",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.popStash(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    try await workplaceRuntimeService.popStash(
                        at: index,
                        for: state,
                        in: workplace
                    )
                }
            },
            onDropStash: { state, index, repositoryName in
                detailActionCoordinator.run(
                    actionName: "删除 Stash",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.dropStash(
                            repositoryName: repositoryName
                        )
                    }
                ) {
                    try await workplaceRuntimeService.dropStash(
                        at: index,
                        for: state,
                        in: workplace
                    )
                }
            },
            onAbortInterruptedOperation: { state, repositoryName in
                detailActionCoordinator.run(
                    actionName: "中止 Git 操作",
                    refreshBranches: true,
                    operation: {
                        try await workplaceRuntimeService.abortInterruptedOperation(
                            for: state,
                            in: workplace
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
                        try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(in: workplace)
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
                        try await workplaceRuntimeService.switchRepositoriesToDefaultBranch(in: workplace)
                    },
                    successFeedback: { result in
                        WorkplaceDetailFeedbackFactory.switchAllToDefaultBranch(result: result)
                    }
                )
            },
            onSwitchAllRepositoriesToWorkBranch: {
                let workBranch = latestWorkplace(for: workplace.id)?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detailActionCoordinator.run(
                    actionName: "批量切到工作分支",
                    refreshBranches: true,
                    operation: {
                        try await workplaceRuntimeService.switchRepositoriesToWorkBranch(in: workplace)
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
                try? workplaceStore.clearFailedStatusesWhereDirectoryExists(workplaceID: workplace.id)
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
                try? settingsStore.updatePreferredOpenActionID(actionID)
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
        guard appViewModel.selectedWorkplaceID == workplaceID else { return }
        detailActionCoordinator.feedback = feedback
    }

    private func latestWorkplace(for id: UUID) -> Workplace? {
        workplaceStore.workplaces.first { $0.id == id }
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

    @MainActor
    private func restoreLastSelectedRoute() {
        // 截图模式下 applyLaunchConfigurationIfNeeded 已指定目标路由,
        // 恢复上次选中会把它覆盖掉(截图场景拍成上次退出时的页面),直接跳过。
        guard launchConfiguration.screenshotScene == nil else { return }
        let settings = settingsStore.settings
        guard let lastRoute = settings.lastSelectedRoute else { return }
        if lastRoute == AppRoute.workplaces.rawValue,
           let idString = settings.lastSelectedWorkplaceID,
           let workplaceID = UUID(uuidString: idString),
           workplaceStore.workplaces.contains(where: { $0.id == workplaceID }) {
            appViewModel.showWorkplace(workplaceID)
        } else if lastRoute == AppRoute.settings.rawValue {
            appViewModel.showRoute(.settings)
        }
    }

    @MainActor
    private func scheduleDiskRefresh() {
        let refreshState = RootSplitDiskRefreshState(
            route: appViewModel.route,
            selectedWorkplaceID: appViewModel.selectedWorkplaceID,
            scenePhase: scenePhase,
            rootPath: settingsStore.settings.workplaceRootPath
        )

        guard refreshTask == nil else { return }
        guard refreshState.canScheduleRefresh else { return }

        let shouldInvalidateBranches = refreshState.shouldInvalidateBranchesAfterRefresh
        let rootPath = refreshState.normalizedRootPath
        refreshTask = Task {
            defer {
                if Task.isCancelled == false, shouldInvalidateBranches {
                    detailActionCoordinator.invalidateBranches()
                }
                refreshTask = nil
            }
            await diskRefreshService.refresh(rootPath: rootPath)
        }
    }

    /// 每小时检查一次更新;仅 App 处于活跃状态时执行。
    /// Task 取消(视图消失)时 sleep 抛错退出循环。
    private func runPeriodicUpdateCheck() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                return // 任务被取消(视图销毁),退出循环
            }
            guard scenePhase == .active else { continue }
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
