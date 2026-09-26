import SwiftUI

struct WorkplaceCreateView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    let workplaceCreateService: WorkplaceCreateService
    @ObservedObject var appViewModel: AppViewModel
    let initialSeed: WorkplaceCreateSeed
    let onDismiss: () -> Void

    @State private var name: String
    @State private var branch: String
    @State private var selectedIDs: Set<UUID>
    @State private var feedback: CCSpaceFeedback?
    @State private var isSubmitting = false
    @State private var repositorySearchText = ""
    @State private var operationProgress: WorkplaceOperationProgress?
    /// 进行中的创建任务:多仓库克隆可达数分钟,没有取消通道时用户只能对着
    /// `interactiveDismissDisabled` 的关不掉的弹窗干等。
    @State private var submitTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        repositoryStore: RepositoryStore,
        workplaceCreateService: WorkplaceCreateService,
        appViewModel: AppViewModel,
        initialSeed: WorkplaceCreateSeed = .empty,
        onDismiss: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.repositoryStore = repositoryStore
        self.workplaceCreateService = workplaceCreateService
        self.appViewModel = appViewModel
        self.initialSeed = initialSeed
        self.onDismiss = onDismiss
        _name = State(initialValue: initialSeed.name)
        _branch = State(initialValue: initialSeed.branch)
        _selectedIDs = State(initialValue: initialSeed.selectedRepositoryIDs)
    }

    private var presentationState: WorkplaceCreatePresentationState {
        WorkplaceCreatePresentationState(
            name: name,
            branch: branch,
            selectedRepositoryCount: selectedIDs.count,
            rootPath: settingsStore.settings.workplaceRootPath,
            isSubmitting: isSubmitting
        )
    }

    private var repositoryOptions: [WorkplaceSelectableRepository] {
        WorkplaceSelectableRepositoryFactory.createOptions(
            repositories: repositoryStore.repositories
        )
    }

    private var progressPresentationState: WorkplaceFormProgressPresentationState? {
        guard let operationProgress else { return nil }
        return WorkplaceFormProgressPresentationState(progress: operationProgress)
    }

    @MainActor
    private func submitCreate() async {
        guard presentationState.canSubmit else { return }

        isSubmitting = true
        feedback = nil
        operationProgress = nil
        defer {
            isSubmitting = false
            operationProgress = nil
        }

        do {
            let sortedIDs = repositoryStore.repositories
                .map(\.id)
                .filter { selectedIDs.contains($0) }
            let workplace = try await workplaceCreateService.createWorkplace(
                name: name,
                rootPath: settingsStore.settings.workplaceRootPath,
                selectedRepositoryIDs: sortedIDs,
                branch: branch,
                progressHandler: { progress in
                    operationProgress = progress
                }
            )
            // 服务已返回但用户恰好点了取消:半成品工作区已建好,不能再来一次
            // "创建成功"跳转;服务内部 catch 会在更早的阶段把取消转成错误抛出。
            try Task.checkCancellation()

            appViewModel.showWorkplace(workplace.id)
            onDismiss()
        } catch is CancellationError {
            // 取消路径:Service 的 catch 已负责删记录/清目录,这里只反馈。
            feedback = CCSpaceFeedback(style: .info, message: "已取消创建，工作区与半成品目录已清理")
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "创建工作区",
                error: error
            )
        }
        submitTask = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkplaceFormFieldsSection(
                        title: "创建工作区",
                        branchQuickHelp: "可选。填写工作分支名称后，会优先切换到远端同名分支；若远端不存在，则基于默认分支创建本地分支。",
                        name: $name,
                        branch: $branch,
                        isDisabled: isSubmitting,
                        branchValidationError: presentationState.branchValidationError,
                        autoFocusName: true,
                        nameHint: "名称会作为根目录下的文件夹名",
                        branchHint: "选填，统一切换分支时使用此名称",
                        onInputChanged: clearFeedback
                    )

                    WorkplaceRepositorySelectionSection(
                        subtitle: presentationState.selectedRepositorySubtitle,
                        repositories: repositoryOptions,
                        selectedIDs: selectedIDs,
                        emptySubtitle: "请先到设置页添加 Git 仓库地址，然后回来勾选需要包含的仓库。",
                        searchText: $repositorySearchText,
                        isDisabled: isSubmitting,
                        onToggle: toggleSelection
                    )

                    if let branchStrategyFeedback = presentationState.branchStrategyFeedback {
                        CCSpaceFeedbackBanner(feedback: branchStrategyFeedback)
                    }

                    if let shownFeedback = feedback {
                        CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
                    } else if let missingRootPathFeedback = presentationState.missingRootPathFeedback {
                        CCSpaceFeedbackBanner(feedback: missingRootPathFeedback)
                    }
                }
                .padding(16)
            }

            Divider()

            WorkplaceFormFooter(
                submitTitle: "创建",
                submittingTitle: "创建中",
                isSubmitting: isSubmitting,
                isSubmitDisabled: !presentationState.canSubmit,
                progress: progressPresentationState,
                onCancel: {
                    if isSubmitting {
                        // 提交中点"取消":终止任务并让 Service 走清理路径,
                        // 而不是留下孤儿工作区后直接关窗。
                        submitTask?.cancel()
                    } else {
                        onDismiss()
                    }
                },
                onSubmit: {
                    submitTask = Task {
                        await submitCreate()
                    }
                }
            )
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 460)
        .navigationTitle("创建工作区")
        .ccspaceAutoDismissFeedback($feedback)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            applySeed(initialSeed)
        }
        .onChange(of: initialSeed) { _, newSeed in
            applySeed(newSeed)
        }
    }

    private func clearFeedback() {
        feedback = nil
    }

    private func applySeed(_ seed: WorkplaceCreateSeed) {
        let appliedState = WorkplaceCreateSeedApplicationState(seed: seed)
        name = appliedState.name
        branch = appliedState.branch
        selectedIDs = appliedState.selectedRepositoryIDs
        repositorySearchText = appliedState.repositorySearchText
        feedback = appliedState.feedback
    }

    private func toggleSelection(_ id: UUID) {
        clearFeedback()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
