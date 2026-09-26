import SwiftUI

struct EditRepositorySheetView: View {
    @ObservedObject var repositoryStore: RepositoryStore
    let repository: RepositoryConfig
    let infoService: RepositoryInfoService
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var editingGitURL: String = ""
    @State private var editingMRBranches: [String] = []
    @State private var mrBranchInput: String = ""
    @State private var feedback: CCSpaceFeedback?
    @State private var effectiveDefaultBranch: String?
    @State private var remoteBranchSuggestions: [String] = []
    @State private var isLoadingRemoteBranches = false
    @State private var probeTask: Task<Void, Never>?
    @State private var showBranchSuggestions = false
    @FocusState private var isMRBranchInputFocused: Bool

    private var canSubmit: Bool {
        // 无任何修改时不可保存,避免空提交;提交条件与被测的 PresentationState 保持一致。
        RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: editingGitURL,
            editingMRBranches: editingMRBranches
        ).canSubmit
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let shownFeedback = feedback {
                        CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        CCSpaceSectionTitle(
                            title: "编辑 \(repository.repoName)",
                            titleFont: .title3,
                            titleWeight: .semibold,
                            titleColor: .primary
                        )

                        TextField("Git 仓库地址", text: $editingGitURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: editingGitURL) { _, _ in
                                feedback = nil
                            }
                            .onSubmit { save() }
                    }
                    .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)

                    VStack(alignment: .leading, spacing: 8) {
                        CCSpaceSectionTitle(
                            title: "选择 MR 目标分支",
                            titleFont: .title3,
                            titleWeight: .semibold,
                            titleColor: .primary
                        )

                        MRTargetBranchPicker(
                            selectedBranches: $editingMRBranches,
                            inputText: $mrBranchInput,
                            suggestions: remoteBranchSuggestions,
                            defaultBranch: effectiveDefaultBranch,
                            isLoading: isLoadingRemoteBranches,
                            showsSuggestions: $showBranchSuggestions,
                            inputFocused: $isMRBranchInputFocused
                        )
                    }
                    .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
                }
                .padding([.top, .horizontal], 16)
            }

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.escape)

                Button {
                    save()
                } label: {
                    Text("保存")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500, height: 490)
        // 与主窗口一致:成功/信息类提示自动消失,错误类保留且可手动关闭。
        .ccspaceAutoDismissFeedback($feedback)
        .onAppear {
            editingGitURL = repository.gitURL
            effectiveDefaultBranch = repository.defaultBranch
            if repository.mrTargetBranches.isEmpty, let defaultBranch = repository.defaultBranch {
                editingMRBranches = [defaultBranch]
            } else {
                editingMRBranches = repository.mrTargetBranches
            }
            // 两个探测合并为一个串行任务并持有句柄:此前是两个裸 Task——
            // 关闭弹窗后仍会跑完(其中 fetchDefaultBranch 会真实写盘),
            // 且两者会竞争 effectiveDefaultBranch(靠事后 reorder 补偿,脆弱)。
            // 先取远端分支建议,再探测默认分支,reorder 时才有数据可排。
            probeTask?.cancel()
            probeTask = Task { @MainActor in
                await loadRemoteBranchSuggestions()
                if repository.defaultBranch == nil {
                    await fetchDefaultBranch()
                }
            }
        }
        .onDisappear {
            // 弹窗关闭后不再写盘、不再向已销毁视图回写状态。
            probeTask?.cancel()
            probeTask = nil
        }
    }

    @MainActor
    private func fetchDefaultBranch() async {
        guard let branch = await infoService.defaultBranch(for: repository.gitURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else { return }
        // cancel 只是"没人等它",异步体必须自查:弹窗已关闭(onDisappear 已 cancel)
        // 时不得再写盘、不得再向已销毁视图回写状态。
        guard Task.isCancelled == false else { return }
        try? repositoryStore.updateDefaultBranch(id: repository.id, branch: branch)
        // repository 是打开弹窗时的快照,默认分支必须写入本地状态才能反映到 chip/建议行。
        effectiveDefaultBranch = branch
        reorderSuggestions(withDefault: branch)
        if editingMRBranches.isEmpty {
            editingMRBranches = [branch]
        }
    }

    @MainActor
    private func loadRemoteBranchSuggestions() async {
        isLoadingRemoteBranches = true
        defer { isLoadingRemoteBranches = false }
        let branches = await infoService.remoteBranches(for: repository.gitURL)
        guard Task.isCancelled == false else { return }
        let defaultBranch = effectiveDefaultBranch
        // 归一排序(localizedStandardCompare)放到后台做:分支上千时不卡弹层主线程,
        // 与 BranchListNormalization 的"加载时归一一次"约定一致。
        // detached 子任务只算纯函数、不触碰共享状态,取消窗口内最多白算一次排序。
        let ordered = await Task.detached(priority: .userInitiated) {
            RepositoryBranchSuggestionOrder.ordered(branches: branches, defaultBranch: defaultBranch)
        }.value
        guard Task.isCancelled == false else { return }
        remoteBranchSuggestions = ordered
        showBranchSuggestions = true
    }

    private func reorderSuggestions(withDefault defaultBranch: String) {
        guard let idx = remoteBranchSuggestions.firstIndex(of: defaultBranch) else { return }
        var result = remoteBranchSuggestions
        result.remove(at: idx)
        result.insert(defaultBranch, at: 0)
        remoteBranchSuggestions = result
    }

    @MainActor
    private func save() {
        let trimmedEditingGitURL = editingGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchesChanged = editingMRBranches != repository.mrTargetBranches
        do {
            feedback = nil
            try repositoryStore.updateRepository(
                id: repository.id,
                gitURL: trimmedEditingGitURL,
                mrTargetBranches: branchesChanged ? editingMRBranches : nil
            )
            onSaved?()
            dismiss()
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "更新仓库", error: error)
        }
    }
}
