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
    /// 本轮提交已发起的同步闸:add() 内部没有任何 await,isAdding 在一次同步执行里
    /// 就 true→false,拦不住同一轮回车同时触发 .onSubmit 与默认按钮的第二次调用。
    /// 跨调用存活,改地址(onChange)、手动关闭错误横幅或重新呈现(.onAppear)后复位,见 add() 注释。
    @State private var hasSubmitted = false
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
        // !hasSubmitted 是不依赖 await 的重入闸,口径见 add() 注释。
        RepositoryAddPresentationState(gitURL: gitURL).canSubmit && !isAdding && !hasSubmitted
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let shownFeedback = feedback {
                        CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: {
                            self.feedback = nil
                            // 手动关闭错误横幅 = 放弃这条错误,重新放开同地址再次提交。
                            self.hasSubmitted = false
                        })
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
                        // 非空但格式非法时先行内提示(与提交时 store 抛错同一口径),
                        // 不等点了"添加"才看到红色错误条。
                        if gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                           RepositoryAddPresentationState(gitURL: gitURL).isURLFormatValid == false {
                            Text("地址格式不正确：需为 https/http/ssh/git 协议或 user@host:path 形式")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
                // hasSubmitted 期间按钮恒禁用:不给提示用户会以为按钮坏了。
                .help(hasSubmitted ? "上一次提交未成功：修改地址或关闭错误提示后可再次提交" : "新增仓库")
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500, height: 450)
        // 与主窗口一致:成功/信息类提示自动消失,错误类保留且可手动关闭。
        .ccspaceAutoDismissFeedback($feedback)
        .onAppear {
            // hasSubmitted 是跨调用存活的 @State 闸(见 add() 注释),不能只依赖
            // ".sheet 每次呈现都重建内容视图"这一隐式假设:显式复位,保证上一次
            // 会话的失败闸不会把新一轮提交永久拦在 canSubmit 之外。
            hasSubmitted = false
        }
        .onChange(of: gitURL) { _, newValue in
            feedback = nil
            // 改地址视为新的一次提交,重新放开同步闸(见 hasSubmitted)。
            hasSubmitted = false
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
        showBranchSuggestions = true
        // 探测(800ms 防抖 + 网络往返)期间用户可能已输入目标分支:
        // 仅在输入为空时预填默认分支并抢焦点,不覆盖用户已敲的内容
        // (与 EditRepositorySheetView.fetchDefaultBranch 的守卫同一口径)。
        if editingMRBranches.isEmpty, let preselected = ordered.first {
            editingMRBranches = [preselected]
            isMRBranchInputFocused = true
        }
    }

    @MainActor
    private func add() async {
        // 两个入口(按钮/回车)统一走这里,守卫与 canSubmit 同口径。
        // 兜住"同一轮双触发"的其实是 !hasSubmitted:add() 全程没有任何 await,
        // isAdding 在一次同步执行内就 true→false,第二个 Task 串行到达时已复位、
        // 拦不下来——第一跑成功后已 dismiss,第二跑会在已关闭的 sheet 上抛
        // duplicateURL,写一条用户看不到的 feedback。失败不复位闸(错误横幅
        // 本身就在打开的 sheet 上,用户看得到):改地址或手动关闭横幅后才允许
        // 再次提交。isAdding 保留,防以后加 await 后中招。
        guard canSubmit else { return }
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        isAdding = true
        hasSubmitted = true
        defer { isAdding = false }
        do {
            // 建档 → 回填 MR 目标分支 → 取实时记录的多步编排在 Orchestrator:
            // 返回的是 update 之后的实时快照,"新增后直接编辑"弹窗的基线才不失真。
            let freshRepository = try RepositoryAddOrchestrator.addRepository(
                gitURL: trimmed,
                mrTargetBranches: editingMRBranches,
                store: repositoryStore
            )
            if let freshRepository {
                onAdded(freshRepository)
            }
            dismiss()
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "新增仓库", error: error)
        }
    }
}
