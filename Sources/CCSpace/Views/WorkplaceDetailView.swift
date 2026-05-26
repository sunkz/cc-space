import SwiftUI
import AppKit

private enum WorkplaceDetailRefreshInterval {
    static let activeGitStatus: TimeInterval = 15
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
    let onSwitchRepositoryToDefaultBranch: (RepositorySyncState, String) -> Void
    let onSwitchRepositoryToWorkBranch: (RepositorySyncState, String) -> Void
    let onMergeRepositoryDefaultBranchIntoCurrent: (RepositorySyncState, String) -> Void
    let onCreateMergeRequest: (RepositorySyncState, RepositoryConfig, String?) -> Void
    let onDeleteRepository: (RepositorySyncState, String) -> Void
    let onMergeDefaultBranchIntoCurrent: () -> Void
    let onSwitchAllRepositoriesToDefaultBranch: () -> Void
    let onSwitchAllRepositoriesToWorkBranch: () -> Void
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
    let preferredOpenActionID: String?
    let onSelectOpenAction: (String) -> Void
    @Binding var feedback: CCSpaceFeedback?
    @State private var branchSnapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
    @State private var showingDeleteConfirmation = false
    @State private var periodicRefreshSeed = 0
    @State private var manualRefreshSeed = 0
    @State private var branchRefreshTask: Task<Void, Never>?
    @State private var hasQueuedBranchRefresh = false
    @State private var lastInteractionTime: Date = .now

    private var workplaceSyncStates: [RepositorySyncState] {
        syncStates
    }

    private var repositoryByID: [UUID: RepositoryConfig] {
        Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    }

    private var sortedWorkplaceSyncStates: [RepositorySyncState] {
        workplaceSyncStates.sorted {
            URL(fileURLWithPath: $0.localPath).lastPathComponent
                .localizedStandardCompare(URL(fileURLWithPath: $1.localPath).lastPathComponent) == .orderedAscending
        }
    }

    private var actionState: WorkplaceActionState {
        WorkplaceActionState(
            workplace: workplace,
            repositories: repositories,
            syncStates: syncStates
        )
    }

    private var openActions: [OpenActionItem] {
        WorkplaceSystemActions.allOpenActions
    }

    private var preferredOpenAction: OpenActionItem {
        WorkplaceSystemActions.preferredOpenAction(id: preferredOpenActionID)
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
        for state in workplaceSyncStates {
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

    private func repoDisplayName(for state: RepositorySyncState) -> String {
        if let config = repositoryByID[state.repositoryID] {
            return config.repoName
        }
        return URL(fileURLWithPath: state.localPath).lastPathComponent
    }

    init(
        workplace: Workplace,
        repositories: [RepositoryConfig],
        syncStates: [RepositorySyncState],
        gitService: GitServicing = GitService(),
        actions: WorkplaceDetailActions = WorkplaceDetailActions(
            onEdit: {},
            onDelete: {},
            onRetry: { _ in },
            onPullAll: {},
            onPush: {},
            onPull: { _ in },
            onPushRepository: { _, _ in },
            onSwitchBranch: { _, _, _ in },
            onSwitchRepositoryToDefaultBranch: { _, _ in },
            onSwitchRepositoryToWorkBranch: { _, _ in },
            onMergeRepositoryDefaultBranchIntoCurrent: { _, _ in },
            onCreateMergeRequest: { _, _, _ in },
            onDeleteRepository: { _, _ in },
            onMergeDefaultBranchIntoCurrent: {},
            onSwitchAllRepositoriesToDefaultBranch: {},
            onSwitchAllRepositoriesToWorkBranch: {},
            onCancelAction: {}
        ),
        isPerformingAction: Bool = false,
        branchRefreshSeed: Int = 0,
        feedback: Binding<CCSpaceFeedback?> = .constant(nil),
        preferredOpenActionID: String? = nil,
        onSelectOpenAction: @escaping (String) -> Void = { _ in }
    ) {
        self.workplace = workplace
        self.repositories = repositories
        self.syncStates = syncStates
        self.gitService = gitService
        self.actions = actions
        self.isPerformingAction = isPerformingAction
        self.branchRefreshSeed = branchRefreshSeed
        self._feedback = feedback
        self.preferredOpenActionID = preferredOpenActionID
        self.onSelectOpenAction = onSelectOpenAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                feedbackBanner
                    .animation(.snappy(duration: 0.25), value: feedback)
                repositorySection
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(12)
        }
        .ccspaceScreenBackground()
        .navigationTitle(workplace.name)
        .toolbar {
            operationProgressToolbarItem
            editToolbarItem
            refreshToolbarItem
            pullToolbarItem
            pushToolbarItem
            switchAllToDefaultBranchToolbarItem
            switchAllToWorkBranchToolbarItem
            openActionToolbarItem
            deleteToolbarItem
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
        .onReceive(
            Timer.publish(
                every: WorkplaceDetailRefreshInterval.activeGitStatus,
                on: .main,
                in: .common
            ).autoconnect()
        ) { _ in
            guard scenePhase == .active else { return }
            guard workplaceSyncStates.contains(where: \.hasLocalDirectory) else { return }
            guard Date.now.timeIntervalSince(lastInteractionTime) < 60 else { return }
            periodicRefreshSeed += 1
        }
        .onChange(of: branchRefreshToken, initial: true) { _, _ in
            scheduleBranchSnapshotRefresh()
        }
        .onDisappear {
            branchRefreshTask?.cancel()
            branchRefreshTask = nil
            hasQueuedBranchRefresh = false
        }
    }

    private var editToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onEdit()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("编辑工作区")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canEditWorkplace)
            .ccspaceQuickHelp(presentationState.editHelp)
        }
    }

    @ToolbarContentBuilder
    private var operationProgressToolbarItem: some ToolbarContent {
        if presentationState.showsOperationProgress {
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

    private var pushToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onPush()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Push 所有仓库")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canPushAllRepositories)
            .ccspaceQuickHelp(presentationState.pushHelp)
        }
    }

    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                requestStatusRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新全部仓库状态")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canRefreshAllRepositories)
            .ccspaceQuickHelp(presentationState.refreshHelp)
        }
    }

    private var pullToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onPullAll()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Pull 所有仓库")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canSyncAllRepositories)
            .ccspaceQuickHelp(presentationState.syncHelp)
        }
    }

    private var switchAllToDefaultBranchToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onSwitchAllRepositoriesToDefaultBranch()
            } label: {
                Label("切到默认分支", systemImage: "arrow.uturn.backward.circle")
            }
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canSwitchRepositoriesToDefaultBranch)
            .ccspaceQuickHelp(presentationState.switchDefaultBranchHelp)
        }
    }

    private var switchAllToWorkBranchToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.onSwitchAllRepositoriesToWorkBranch()
            } label: {
                Label("切到工作分支", systemImage: "hammer.circle")
            }
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canSwitchRepositoriesToWorkBranch)
            .ccspaceQuickHelp(presentationState.switchWorkBranchHelp)
        }
    }

    private var openActionToolbarItem: some ToolbarContent {
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
            .disabled(!presentationState.canOpenDirectory)
            .ccspaceQuickHelp("在 \(preferredOpenAction.displayName) 中打开")
        }
    }

    private var deleteToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("删除工作区")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canDeleteWorkplace)
            .ccspaceQuickHelp(presentationState.deleteHelp)
        }
    }

    private func loadBranches() async {
        let localSyncStates = workplaceSyncStates.filter(\.hasLocalDirectory)
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

            branchRefreshTask = nil
        }
    }

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            if workplaceSyncStates.isEmpty {
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
                        let branchSnapshot = branchSnapshots[RepositoryBranchCacheKey(state: state)]
                        let repository = repositoryByID[state.repositoryID]
                        let workBranch = workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let repositoryName = repoDisplayName(for: state)
                        WorkplaceRepositoryRowView(
                            state: state,
                            repository: repository,
                            displayName: repositoryName,
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
                            actionsDisabled: presentationState.isActionLocked,
                            openActions: openActions,
                            preferredOpenAction: preferredOpenAction,
                            onOpenAction: handleOpenAction,
                            gitService: gitService,
                            onDelete: {
                                actions.onDeleteRepository(state, repositoryName)
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        }
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
            feedback = WorkplaceDetailFeedbackFactory.refreshRepositoryStatus(
                repositoryName: repositoryName
            )
        } else {
            feedback = WorkplaceDetailFeedbackFactory.refreshAllRepositoryStatuses(
                repositoryCount: workplaceSyncStates.filter(\.hasLocalDirectory).count
            )
        }
        manualRefreshSeed += 1
        lastInteractionTime = .now
    }
}
