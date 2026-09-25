import SwiftUI

struct AddRepositorySheetView: View {
    @ObservedObject var repositoryStore: RepositoryStore
    let infoService: RepositoryInfoService
    let onAdded: (RepositoryConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gitURL: String = ""
    @State private var editingMRBranches: [String] = []
    @State private var mrBranchInput: String = ""
    @State private var feedback: CCSpaceFeedback?
    @State private var isAdding = false
    @State private var remoteBranchSuggestions: [String] = []
    @State private var isLoadingRemoteBranches = false
    @State private var showBranchSuggestions = false
    @State private var didAttemptRemoteFetch = false
    @State private var autoFetchTask: Task<Void, Never>?
    @FocusState private var isMRBranchInputFocused: Bool

    private var defaultBranch: String? {
        remoteBranchSuggestions.first
    }

    private var canSubmit: Bool {
        // 远端分支探测只用于预填 MR 目标分支,不阻塞新增(离线/网络慢时应仍可提交)。
        RepositoryAddPresentationState(gitURL: gitURL).canSubmit && !isAdding
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let feedback {
                        CCSpaceFeedbackBanner(feedback: feedback)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        CCSpaceSectionTitle(
                            title: "新增 Git 仓库",
                            titleFont: .title3,
                            titleWeight: .semibold,
                            titleColor: .primary
                        )

                        TextField("粘贴 Git 仓库地址（HTTPS 或 SSH）", text: $gitURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await add() }
                            }
                    }
                    .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)

                    VStack(alignment: .leading, spacing: 8) {
                        CCSpaceSectionTitle(
                            title: "选择 MR 目标分支",
                            titleFont: .title3,
                            titleWeight: .semibold,
                            titleColor: .primary
                        )

                        if didAttemptRemoteFetch, remoteBranchSuggestions.isEmpty, !isLoadingRemoteBranches {
                            Text("未能获取远端分支（可能是网络原因），可先新增，稍后在编辑中补充目标分支。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        MRTargetBranchPicker(
                            selectedBranches: $editingMRBranches,
                            inputText: $mrBranchInput,
                            suggestions: remoteBranchSuggestions,
                            defaultBranch: defaultBranch,
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
                    Task { await add() }
                } label: {
                    if isAdding {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("新增中")
                        }
                    } else {
                        Text("新增")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500, height: 450)
        .onChange(of: gitURL) { _, newValue in
            feedback = nil
            autoFetchTask?.cancel()
            didAttemptRemoteFetch = false
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            autoFetchTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                let url = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                await fetchRemoteBranchesAndDefault(for: url)
            }
        }
        .onDisappear {
            // sheet 关闭时取消防抖取数任务,避免对已销毁视图的迟到状态写入。
            autoFetchTask?.cancel()
            autoFetchTask = nil
        }
    }

    @MainActor
    private func fetchRemoteBranchesAndDefault(for url: String) async {
        guard !url.isEmpty else { return }
        isLoadingRemoteBranches = true
        defer {
            isLoadingRemoteBranches = false
            didAttemptRemoteFetch = true
        }

        let (branches, defaultBranch) = await infoService.probeRemote(gitURL: url)

        // 探测期间用户可能继续输入:URL 已变则丢弃过期结果,避免旧建议覆盖新输入。
        guard !Task.isCancelled,
              gitURL.trimmingCharacters(in: .whitespacesAndNewlines) == url else { return }

        // 排序(localizedStandardCompare)放到后台做:分支上千时不卡弹层主线程,
        // 与 BranchListNormalization 的"加载时归一一次"约定一致。
        let ordered = await Task.detached(priority: .userInitiated) {
            RepositoryBranchSuggestionOrder.ordered(branches: branches, defaultBranch: defaultBranch)
        }.value

        // 后台排序期间输入仍可能变化:回主线程赋值前再校验一次。
        guard !Task.isCancelled,
              gitURL.trimmingCharacters(in: .whitespacesAndNewlines) == url else { return }

        remoteBranchSuggestions = ordered
        if let preselected = ordered.first {
            editingMRBranches = [preselected]
        }

        showBranchSuggestions = true
        isMRBranchInputFocused = true
    }

    @MainActor
    private func add() async {
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAdding = true
        do {
            try repositoryStore.addRepository(gitURL: trimmed)
            if let newRepo = repositoryStore.repositories.first(where: { $0.gitURL == trimmed }) {
                if !editingMRBranches.isEmpty {
                    try repositoryStore.updateRepository(
                        id: newRepo.id,
                        gitURL: trimmed,
                        mrTargetBranches: editingMRBranches
                    )
                }
                onAdded(newRepo)
            }
            dismiss()
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "新增仓库", error: error)
        }
        isAdding = false
    }
}
