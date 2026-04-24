import SwiftUI

struct RootSplitView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appViewModel = AppViewModel()
    @StateObject private var detailActionCoordinator = WorkplaceDetailActionCoordinator()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var repositoryStore: RepositoryStore
    @StateObject private var workplaceStore: WorkplaceStore
    @State private var editingWorkplace: Workplace?
    @State private var showingCreateSheet = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var createWorkplaceSeed = WorkplaceCreateSeed.empty
    @State private var hasAppliedLaunchConfiguration = false
    private let launchConfiguration: CCSpaceLaunchConfiguration
    private let syncCoordinator: SyncCoordinator
    private let gitService: GitService

    private var selectedWorkplace: Workplace? {
        guard let selectedID = appViewModel.selectedWorkplaceID else { return nil }
        return workplaceStore.workplaces.first { $0.id == selectedID }
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

    init(launchConfiguration: CCSpaceLaunchConfiguration = CCSpaceLaunchConfiguration()) {
        self.launchConfiguration = launchConfiguration

        let appSupport: URL
        if let overrideDirectory = launchConfiguration.appSupportDirectory {
            appSupport = overrideDirectory
        } else {
            guard let appSupportBase = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first else {
                fatalError("Application Support directory unavailable")
            }
            appSupport = appSupportBase
                .appendingPathComponent("CCSpace", isDirectory: true)
        }
        let fileStore = JSONFileStore(rootDirectory: appSupport)
        _settingsStore = StateObject(wrappedValue: SettingsStore(fileStore: fileStore))
        _repositoryStore = StateObject(wrappedValue: RepositoryStore(fileStore: fileStore))
        _workplaceStore = StateObject(wrappedValue: WorkplaceStore(fileStore: fileStore))
        let git = GitService()
        gitService = git
        syncCoordinator = SyncCoordinator(gitService: git)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                appViewModel: appViewModel,
                workplaceStore: workplaceStore,
                hasUpdate: updateChecker.hasUpdate,
                onCreateWorkplace: { showingCreateSheet = true }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 250)
        } detail: {
            switch appViewModel.route {
            case .settings:
                SettingsView(
                    settingsStore: settingsStore,
                    repositoryStore: repositoryStore,
                    workplaceStore: workplaceStore,
                    gitService: gitService
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
        .task {
            await updateChecker.check()
        }
        .onReceive(Timer.publish(every: 3600, on: .main, in: .common).autoconnect()) { _ in
            Task { await updateChecker.check() }
        }
        .onAppear {
            applyLaunchConfigurationIfNeeded()
            scheduleDiskRefresh()
        }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            scheduleDiskRefresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            scheduleDiskRefresh()
        }
        .onChange(of: appViewModel.selectedWorkplaceID) { _, _ in
            detailActionCoordinator.feedback = nil
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 480)
        .animation(.snappy(duration: 0.22), value: appViewModel.sidebarSelection)
        .sheet(item: $editingWorkplace) { workplace in
            WorkplaceEditView(
                workplace: workplace,
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
        .sheet(isPresented: $showingCreateSheet) {
            WorkplaceCreateView(
                settingsStore: settingsStore,
                repositoryStore: repositoryStore,
                workplaceCreateService: workplaceCreateService,
                appViewModel: appViewModel,
                initialSeed: createWorkplaceSeed,
                onDismiss: { showingCreateSheet = false }
            )
        }
    }

    private func detailView(for workplace: Workplace) -> some View {
        WorkplaceDetailView(
            workplace: workplace,
            repositories: repositoryStore.repositories,
            syncStates: workplaceStore.syncStates,
            gitService: gitService,
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
            onPush: {
                var result: RepositoryPushResult?
                detailActionCoordinator.run(
                    actionName: "推送工作区",
                    successFeedback: {
                        guard let result else { return nil }
                        return WorkplaceDetailFeedbackFactory.pushAll(result: result)
                    }
                ) {
                    result = try await workplaceRuntimeService.pushRepositories(in: workplace)
                }
            },
            onPull: { repository in
                var result: RepositoryPullResult?
                detailActionCoordinator.run(
                    actionName: "同步仓库",
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.syncRepository(
                            repositoryName: repository.repoName,
                            result: result ?? RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 0),
                            syncState: syncState(
                                workplaceID: workplace.id,
                                repositoryID: repository.id
                            )
                        )
                    }
                ) {
                    result = await workplaceRuntimeService.pullRepositories(
                        in: workplace,
                        repositoryID: repository.id
                    )
                }
            },
            onPushRepository: { state, repositoryName in
                var outcome: RepositoryPushOutcome?
                detailActionCoordinator.run(
                    actionName: "推送仓库",
                    refreshBranches: true,
                    successFeedback: {
                        guard let outcome else { return nil }
                        return WorkplaceDetailFeedbackFactory.pushRepository(
                            repositoryName: repositoryName,
                            outcome: outcome,
                            syncState: syncState(
                                workplaceID: workplace.id,
                                repositoryID: state.repositoryID
                            )
                        )
                    }
                ) {
                    outcome = try await workplaceRuntimeService.pushRepository(
                        for: state,
                        in: workplace
                    )
                }
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
            onSwitchRepositoryToDefaultBranch: { state, repositoryName in
                var defaultBranch = ""
                detailActionCoordinator.run(
                    actionName: "切换到默认分支",
                    refreshBranches: true,
                    successFeedback: {
                        WorkplaceDetailFeedbackFactory.switchRepositoryToDefaultBranch(
                            repositoryName: repositoryName,
                            branch: defaultBranch
                        )
                    }
                ) {
                    defaultBranch = try await workplaceRuntimeService.switchRepositoryToDefaultBranch(
                        for: state,
                        in: workplace
                    )
                }
            },
            onSwitchRepositoryToWorkBranch: { state, repositoryName in
                let workBranch = latestWorkplace(for: workplace.id)?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detailActionCoordinator.run(
                    actionName: "切换到工作分支",
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
                var outcome: GitMergeDefaultBranchOutcome?
                detailActionCoordinator.run(
                    actionName: "合并默认分支",
                    refreshBranches: true,
                    successFeedback: {
                        guard let outcome else { return nil }
                        return WorkplaceDetailFeedbackFactory.mergeRepositoryDefaultBranchIntoCurrent(
                            repositoryName: repositoryName,
                            outcome: outcome
                        )
                    }
                ) {
                    outcome = try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(
                        for: state,
                        in: workplace
                    )
                }
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
            onMergeDefaultBranchIntoCurrent: {
                var result: WorkplaceBulkBranchSwitchResult?
                detailActionCoordinator.run(
                    actionName: "合并默认分支",
                    refreshBranches: true,
                    successFeedback: {
                        guard let result else { return nil }
                        return WorkplaceDetailFeedbackFactory.mergeDefaultBranchIntoCurrent(result: result)
                    }
                ) {
                    result = try await workplaceRuntimeService.mergeDefaultBranchIntoCurrent(in: workplace)
                }
            },
            onSwitchAllRepositoriesToDefaultBranch: {
                var result: WorkplaceBulkBranchSwitchResult?
                detailActionCoordinator.run(
                    actionName: "批量切换到默认分支",
                    refreshBranches: true,
                    successFeedback: {
                        guard let result else { return nil }
                        return WorkplaceDetailFeedbackFactory.switchAllToDefaultBranch(result: result)
                    }
                ) {
                    result = try await workplaceRuntimeService.switchRepositoriesToDefaultBranch(in: workplace)
                }
            },
            onSwitchAllRepositoriesToWorkBranch: {
                let workBranch = latestWorkplace(for: workplace.id)?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var result: WorkplaceBulkBranchSwitchResult?
                detailActionCoordinator.run(
                    actionName: "批量切换到工作分支",
                    refreshBranches: true,
                    successFeedback: {
                        guard let result else { return nil }
                        return WorkplaceDetailFeedbackFactory.switchAllToWorkBranch(
                            branch: workBranch,
                            result: result
                        )
                    }
                ) {
                    result = try await workplaceRuntimeService.switchRepositoriesToWorkBranch(in: workplace)
                }
            },
            isPerformingAction: detailActionCoordinator.isRunningAction,
            branchRefreshSeed: detailActionCoordinator.branchRefreshSeed,
            feedback: $detailActionCoordinator.feedback,
            preferredOpenActionID: settingsStore.settings.preferredOpenActionID,
            onSelectOpenAction: { actionID in
                try? settingsStore.updatePreferredOpenActionID(actionID)
            }
        )
        .id(workplace.id)
    }

    private var emptyWorkplaceState: some View {
        VStack {
            ContentUnavailableView {
                Label("选择工作区", systemImage: "folder")
            } actions: {
                Button("新建") {
                    showingCreateSheet = true
                }
                .ccspacePrimaryActionButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ccspaceScreenBackground()
    }

    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if appViewModel.route == .settings {
            ToolbarItem(placement: .primaryAction) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("获取更新 ↗", action: openReleasesPage)
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .ccspaceQuickHelp("前往 Releases 下载最新版本")

                    toolbarVersionText
                }
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
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

        createWorkplaceSeed = launchConfiguration.createWorkplaceSeed(
            repositories: repositoryStore.repositories
        )

        switch screenshotScene {
        case .settingsOverview:
            appViewModel.showRoute(.settings)
            showingCreateSheet = false
        case .workplaceDetail:
            if let workplace = launchConfiguration.targetWorkplace(
                in: workplaceStore.workplaces
            ) {
                appViewModel.showWorkplace(workplace.id)
            } else {
                appViewModel.showRoute(.workplaces)
            }
            showingCreateSheet = false
        case .createWorkplace:
            if let workplace = launchConfiguration.targetWorkplace(
                in: workplaceStore.workplaces
            ) {
                appViewModel.showWorkplace(workplace.id)
            } else {
                appViewModel.showRoute(.workplaces)
            }
            showingCreateSheet = true
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
}
