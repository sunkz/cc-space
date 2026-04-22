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

                    if let feedback {
                        CCSpaceFeedbackBanner(feedback: feedback)
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
        .interactiveDismissDisabled(isSaving)
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
