import SwiftUI

struct WorkplaceEditView: View {
    let workplace: Workplace
    let repositories: [RepositoryConfig]
    let syncStates: [RepositorySyncState]
    let onSave: (String, [UUID], String?, WorkplaceOperationProgressHandler?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRepositoryIDs: Set<UUID>
    @State private var name: String
    @State private var branch: String
    @State private var isSaving = false
    @State private var feedback: CCSpaceFeedback?
    @State private var repositorySearchText = ""
    @State private var operationProgress: WorkplaceOperationProgress?
    @State private var isConfirmingRepositoryRemoval = false

    private var presentationState: WorkplaceEditPresentationState {
        WorkplaceEditPresentationState(
            originalName: workplace.name,
            name: name,
            originalBranch: workplace.branch,
            branch: branch,
            originalSelectedRepositoryIDs: workplace.selectedRepositoryIDs,
            selectedRepositoryIDs: selectedRepositoryIDs,
            isSaving: isSaving
        )
    }

    private var repositoryOptions: [WorkplaceSelectableRepository] {
        WorkplaceSelectableRepositoryFactory.editOptions(
            workplace: workplace,
            repositories: repositories,
            syncStates: syncStates
        )
    }

    init(
        workplace: Workplace,
        repositories: [RepositoryConfig],
        syncStates: [RepositorySyncState] = [],
        onSave: @escaping (String, [UUID], String?, WorkplaceOperationProgressHandler?) async throws -> Void = {
            _, _, _, _ in
        }
    ) {
        self.workplace = workplace
        self.repositories = repositories
        self.syncStates = syncStates
        self.onSave = onSave
        _selectedRepositoryIDs = State(initialValue: Set(workplace.selectedRepositoryIDs))
        _name = State(initialValue: workplace.name)
        _branch = State(initialValue: workplace.branch ?? "")
    }

    private var orderedSelectedRepositoryIDs: [UUID] {
        repositoryOptions.map(\.id).filter { selectedRepositoryIDs.contains($0) }
    }

    private var normalizedBranch: String? {
        WorkplaceFormTextNormalization.normalizedOptionalText(branch)
    }

    private var progressPresentationState: WorkplaceFormProgressPresentationState? {
        guard let operationProgress else { return nil }
        return WorkplaceFormProgressPresentationState(progress: operationProgress)
    }

    @MainActor
    private func submitEdit() async {
        guard presentationState.canSubmit else { return }
        // 取消勾选会让保存流程删除对应仓库的本地目录(含未提交改动),
        // 表单里唯一的破坏性动作只有一条内联警告,挡不住误点——保存前强制确认。
        guard presentationState.removedRepositoryCount > 0 else {
            await performSave()
            return
        }
        isConfirmingRepositoryRemoval = true
    }

    @MainActor
    private func performSave() async {
        isConfirmingRepositoryRemoval = false
        isSaving = true
        feedback = nil
        operationProgress = nil
        defer {
            isSaving = false
            operationProgress = nil
        }

        do {
            try await onSave(
                name,
                orderedSelectedRepositoryIDs,
                normalizedBranch,
                { progress in
                    operationProgress = progress
                }
            )
            dismiss()
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "保存工作区",
                error: error
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkplaceFormFieldsSection(
                        title: "编辑工作区",
                        branchQuickHelp: "可选。清空会移除工作分支配置；修改工作分支名称后，会切换已保留的本地仓库，已在目标分支上的仓库会自动跳过。",
                        name: $name,
                        branch: $branch,
                        isDisabled: isSaving,
                        branchValidationError: presentationState.branchValidationError,
                        autoFocusName: true,
                        nameHint: "名称会作为根目录下的文件夹名",
                        branchHint: "选填，统一切换分支时使用此名称",
                        onInputChanged: clearFeedback
                    )

                    WorkplaceRepositorySelectionSection(
                        subtitle: presentationState.selectedRepositorySubtitle,
                        repositories: repositoryOptions,
                        selectedIDs: selectedRepositoryIDs,
                        emptySubtitle: "",
                        searchText: $repositorySearchText,
                        isDisabled: isSaving,
                        onToggle: toggleSelection
                    )

                    if let removalWarningFeedback = presentationState.removalWarningFeedback {
                        CCSpaceFeedbackBanner(feedback: removalWarningFeedback)
                    }

                    if let changeSummaryFeedback = presentationState.changeSummaryFeedback {
                        CCSpaceFeedbackBanner(feedback: changeSummaryFeedback)
                    }

                    if let branchChangeFeedback = presentationState.branchChangeFeedback {
                        CCSpaceFeedbackBanner(feedback: branchChangeFeedback)
                    }

                    if let shownFeedback = feedback {
                        CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
                    }
                }
                .padding(16)
            }

            Divider()

            WorkplaceFormFooter(
                submitTitle: "保存",
                submittingTitle: "保存中",
                isSubmitting: isSaving,
                isSubmitDisabled: !presentationState.canSubmit,
                progress: progressPresentationState,
                onCancel: {
                    dismiss()
                },
                onSubmit: {
                    Task {
                        await submitEdit()
                    }
                }
            )
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 460)
        .navigationTitle("编辑工作区")
        .ccspaceAutoDismissFeedback($feedback)
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "确认保存这些改动？",
            isPresented: $isConfirmingRepositoryRemoval,
            titleVisibility: .visible
        ) {
            Button("移除仓库并删除本地目录", role: .destructive) {
                Task {
                    await performSave()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除 \(presentationState.removedRepositoryCount) 个仓库，其本地目录如已存在会一并删除（包含未提交的改动），此操作不可撤销。")
        }
    }

    private func clearFeedback() {
        feedback = nil
    }

    private func toggleSelection(_ id: UUID) {
        clearFeedback()
        if selectedRepositoryIDs.contains(id) {
            selectedRepositoryIDs.remove(id)
        } else {
            selectedRepositoryIDs.insert(id)
        }
    }
}
