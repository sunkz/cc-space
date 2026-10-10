import SwiftUI

struct WorkplaceEditView: View {
    let workplace: Workplace
    let repositories: [RepositoryConfig]
    let syncStates: [RepositorySyncState]
    var onSave: (String, [UUID], String?, [CommonLink], WorkplaceOperationProgressHandler?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRepositoryIDs: Set<UUID>
    @State private var name: String
    @State private var branch: String
    @State private var linkRows: [CommonLink]
    @State private var isSaving = false
    @State private var feedback: CCSpaceFeedback?
    @State private var repositorySearchText = ""
    @State private var operationProgress: WorkplaceOperationProgress?
    @State private var isConfirmingRepositoryRemoval = false
    /// 进行中的保存任务:新增仓库会克隆,单仓最长 600 秒才超时,
    /// 没有句柄就没有中止通道,用户只能对着 `interactiveDismissDisabled` 的弹窗干等。
    @State private var saveTask: Task<Void, Never>?

    private var presentationState: WorkplaceEditPresentationState {
        WorkplaceEditPresentationState(
            originalName: workplace.name,
            name: name,
            originalBranch: workplace.branch,
            branch: branch,
            originalSelectedRepositoryIDs: workplace.selectedRepositoryIDs,
            selectedRepositoryIDs: selectedRepositoryIDs,
            originalLinks: workplace.links,
            editingLinks: linkRows,
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
        onSave: @escaping (String, [UUID], String?, [CommonLink], WorkplaceOperationProgressHandler?) async throws -> Void = {
            _, _, _, _, _ in
        }
    ) {
        self.workplace = workplace
        self.repositories = repositories
        self.syncStates = syncStates
        self.onSave = onSave
        _selectedRepositoryIDs = State(initialValue: Set(workplace.selectedRepositoryIDs))
        _name = State(initialValue: workplace.name)
        _branch = State(initialValue: workplace.branch ?? "")
        _linkRows = State(initialValue: workplace.links)
    }

    private var orderedSelectedRepositoryIDs: [UUID] {
        repositoryOptions.map(\.id).filter { selectedRepositoryIDs.contains($0) }
    }

    private var normalizedBranch: String? {
        WorkplaceFormTextNormalization.normalizedOptionalText(branch)
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
            saveTask = nil
        }

        do {
            try await onSave(
                name,
                orderedSelectedRepositoryIDs,
                normalizedBranch,
                CommonLinksInput.normalizedForSave(rows: linkRows),
                { progress in
                    operationProgress = progress
                }
            )
            dismiss()
        } catch is CancellationError {
            // 取消路径:Service 的 catch 已把本次改动整体回滚(删掉已启动的克隆目录、
            // 恢复改名/分支/被移出的仓库),这里只反馈并留在弹窗里让用户改完再存。
            feedback = CCSpaceFeedback(style: .info, message: "已中止保存，工作区已回滚到改动前的状态")
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

                    VStack(alignment: .leading, spacing: 8) {
                        CCSpaceSectionTitle(
                            title: "常用链接",
                            subtitle: "需求文档 / 环境地址等本工作区常用链接，保存后可在详情页工具栏打开",
                            titleFont: .title3,
                            titleWeight: .semibold,
                            titleColor: .primary
                        )

                        CommonLinksEditor(rows: $linkRows, isDisabled: isSaving)
                    }
                    .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)

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
                progress: operationProgress,
                // 保存中取消按钮改用作"中止":中止走 saveTask?.cancel() 的回滚通道,
                // 而不是留下半途改动直接关窗。
                isCancelDisabledWhileSubmitting: false,
                onCancel: {
                    if isSaving {
                        saveTask?.cancel()
                    } else {
                        dismiss()
                    }
                },
                onSubmit: {
                    saveTask = Task {
                        await submitEdit()
                    }
                }
            )
        }
        // 弹窗尺寸固定 520×550(10-10 用户定案):与创建工作区同值,宽高均不可拖拽。
        .frame(width: 520, height: 550)
        .navigationTitle("编辑工作区")
        .ccspaceAutoDismissFeedback($feedback)
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "确认保存这些改动？",
            isPresented: $isConfirmingRepositoryRemoval,
            titleVisibility: .visible
        ) {
            Button("移除仓库并删除本地目录", role: .destructive) {
                saveTask = Task {
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
