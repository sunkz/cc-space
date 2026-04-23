import SwiftUI
import AppKit

private enum WorkplaceDetailRefreshInterval {
    static let activeGitStatus: TimeInterval = 15
}

struct WorkplaceDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    let workplace: Workplace
    let repositories: [RepositoryConfig]
    let syncStates: [RepositorySyncState]
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRetry: (RepositoryConfig) -> Void
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
    let isPerformingAction: Bool
    let branchRefreshSeed: Int
    let gitService: GitServicing
    let preferredOpenActionID: String?
    let onSelectOpenAction: (String) -> Void
    @Binding var feedback: CCSpaceFeedback?
    @State private var branchSnapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
    @State private var showingDeleteConfirmation = false
    @State private var periodicRefreshSeed = 0

    private var workplaceSyncStates: [RepositorySyncState] {
        syncStates.filter { $0.workplaceID == workplace.id }
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
        onEdit: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onRetry: @escaping (RepositoryConfig) -> Void = { _ in },
        onPush: @escaping () -> Void = {},
        onPull: @escaping (RepositoryConfig) -> Void = { _ in },
        onPushRepository: @escaping (RepositorySyncState, String) -> Void = { _, _ in },
        onSwitchBranch: @escaping (RepositorySyncState, String, String) -> Void = { _, _, _ in },
        onSwitchRepositoryToDefaultBranch: @escaping (RepositorySyncState, String) -> Void = { _, _ in },
        onSwitchRepositoryToWorkBranch: @escaping (RepositorySyncState, String) -> Void = { _, _ in },
        onMergeRepositoryDefaultBranchIntoCurrent: @escaping (RepositorySyncState, String) -> Void = { _, _ in },
        onCreateMergeRequest: @escaping (RepositorySyncState, RepositoryConfig, String?) -> Void = { _, _, _ in },
        onDeleteRepository: @escaping (RepositorySyncState, String) -> Void = { _, _ in },
        onMergeDefaultBranchIntoCurrent: @escaping () -> Void = {},
        onSwitchAllRepositoriesToDefaultBranch: @escaping () -> Void = {},
        onSwitchAllRepositoriesToWorkBranch: @escaping () -> Void = {},
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
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onRetry = onRetry
        self.onPush = onPush
        self.onPull = onPull
        self.onPushRepository = onPushRepository
        self.onSwitchBranch = onSwitchBranch
        self.onSwitchRepositoryToDefaultBranch = onSwitchRepositoryToDefaultBranch
        self.onSwitchRepositoryToWorkBranch = onSwitchRepositoryToWorkBranch
        self.onMergeRepositoryDefaultBranchIntoCurrent = onMergeRepositoryDefaultBranchIntoCurrent
        self.onCreateMergeRequest = onCreateMergeRequest
        self.onDeleteRepository = onDeleteRepository
        self.onMergeDefaultBranchIntoCurrent = onMergeDefaultBranchIntoCurrent
        self.onSwitchAllRepositoriesToDefaultBranch = onSwitchAllRepositoriesToDefaultBranch
        self.onSwitchAllRepositoriesToWorkBranch = onSwitchAllRepositoriesToWorkBranch
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
            pushToolbarItem
            switchAllToDefaultBranchToolbarItem
            switchAllToWorkBranchToolbarItem
            openActionToolbarItem
            deleteToolbarItem
        }
        .animation(.snappy(duration: 0.22), value: repositories.count)
        .animation(.snappy(duration: 0.22), value: syncStates)
        .alert(
            deleteConfirmationState.title,
            isPresented: $showingDeleteConfirmation
        ) {
            Button(deleteConfirmationState.confirmLabel, role: .destructive) {
                onDelete()
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
            periodicRefreshSeed += 1
        }
        .task(id: branchRefreshToken) {
            await loadBranches()
        }
    }

    private var editToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
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
                ProgressView()
                    .ccspaceToolbarStatusIndicator()
                    .ccspaceQuickHelp("工作区操作进行中")
            }
        }
    }

    private var pushToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                onPush()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("推送仓库")
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canPushAllRepositories)
            .ccspaceQuickHelp(presentationState.pushHelp)
        }
    }

    private var switchAllToDefaultBranchToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                onSwitchAllRepositoriesToDefaultBranch()
            } label: {
                Label("默认分支", systemImage: "arrow.uturn.backward.circle")
            }
            .ccspaceToolbarActionButton(prominent: true)
            .disabled(!presentationState.canSwitchRepositoriesToDefaultBranch)
            .ccspaceQuickHelp(presentationState.switchDefaultBranchHelp)
        }
    }

    private var switchAllToWorkBranchToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                onSwitchAllRepositoriesToWorkBranch()
            } label: {
                Label("工作分支名称", systemImage: "hammer.circle")
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
                    subtitle: "",
                    systemImage: "shippingbox",
                    tint: .accentColor
                ) {
                    Button("编辑") {
                        onEdit()
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
                            onRetry: onRetry,
                            onPull: onPull,
                            onPush: {
                                onPushRepository(state, repositoryName)
                            },
                            onSwitchBranch: { branch in
                                onSwitchBranch(state, repositoryName, branch)
                            },
                            onSwitchToDefaultBranch: {
                                onSwitchRepositoryToDefaultBranch(state, repositoryName)
                            },
                            onSwitchToWorkBranch: {
                                guard let workBranch, workBranch.isEmpty == false else { return }
                                onSwitchRepositoryToWorkBranch(state, repositoryName)
                            },
                            showsWorkBranchAction: workBranch?.isEmpty == false,
                            onMergeDefaultBranchIntoCurrent: {
                                onMergeRepositoryDefaultBranchIntoCurrent(state, repositoryName)
                            },
                            onCreateMergeRequest: { repository, targetBranch in
                                onCreateMergeRequest(state, repository, targetBranch)
                            },
                            actionsDisabled: presentationState.isActionLocked,
                            openActions: openActions,
                            preferredOpenAction: preferredOpenAction,
                            onOpenAction: handleOpenAction,
                            gitService: gitService,
                            onDelete: {
                                onDeleteRepository(state, repositoryName)
                            }
                        )
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
}
