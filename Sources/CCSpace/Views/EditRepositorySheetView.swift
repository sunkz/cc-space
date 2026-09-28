import os
import SwiftUI

private let editRepositorySheetViewLog = Logger(
    subsystem: "com.ccspace.app",
    category: "EditRepositorySheetView"
)

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
    /// 更换 gitURL 后的防抖重探任务:与 onAppear 的初始探测分开持有,
    /// 避免新地址探测取消掉仍需写盘的默认分支初始任务。
    @State private var gitURLProbeTask: Task<Void, Never>?
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
                            // 回车提交与"保存"按钮同一可用性口径:地址清空/未改动时
                            // 直接走到 store 会抛错弹红条,禁用态下应是空操作。
                            .onSubmit { if canSubmit { save() } }
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
                await loadRemoteBranchSuggestions(for: repository.gitURL)
                if repository.defaultBranch == nil {
                    await fetchDefaultBranch()
                }
            }
        }
        .onDisappear {
            // 弹窗关闭后不再写盘、不再向已销毁视图回写状态。
            probeTask?.cancel()
            probeTask = nil
            gitURLProbeTask?.cancel()
            gitURLProbeTask = nil
        }
    }

    /// 改址后旧远端探测结果作废:防抖重探分支建议与默认分支,
    /// 避免"新 URL + 旧远端查出的 MR 目标分支"一起被保存(同 AddRepositorySheetView 的做法)。
    private func scheduleRemoteProbe(for rawValue: String) {
        gitURLProbeTask?.cancel()
        let url = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空地址或改回原地址不重探:onAppear 的探测结果仍对应当前保存的地址。
        guard url.isEmpty == false, url != repository.gitURL else { return }
        // 旧地址的在途探测(含默认分支回写)一并作废,慢探测迟到不得覆盖新结果。
        probeTask?.cancel()
        probeTask = nil
        gitURLProbeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard Task.isCancelled == false else { return }
            await loadRemoteBranchSuggestions(for: url)
            guard Task.isCancelled == false else { return }
            await previewDefaultBranch(for: url)
        }
    }

    /// 新地址的默认分支只更新弹层内预览,不写 Store:地址尚未保存,
    /// 用户取消编辑时 Store 仍是旧地址,写盘会用新地址的分支污染旧配置。
    @MainActor
    private func previewDefaultBranch(for gitURL: String) async {
        guard let branch = await infoService.defaultBranch(for: gitURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            branch.isEmpty == false else { return }
        guard Task.isCancelled == false else { return }
        effectiveDefaultBranch = branch
        reorderSuggestions(withDefault: branch)
    }

    @MainActor
    private func fetchDefaultBranch() async {
        guard let branch = await infoService.defaultBranch(for: repository.gitURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else { return }
        // cancel 只是"没人等它",异步体必须自查:弹窗已关闭(onDisappear 已 cancel)
        // 时不得再写盘、不得再向已销毁视图回写状态。
        guard Task.isCancelled == false else { return }
        // 不再 `try?` 静默吞掉写盘失败:磁盘满/权限问题既要留痕也要让用户看到——
        // 只写日志的话界面仍像保存成功,下次打开弹窗默认分支又变回旧值;
        // 失败时本地状态也一并停在旧值(见 catch 内 return),与红条自洽。
        do {
            try repositoryStore.updateDefaultBranch(id: repository.id, branch: branch)
        } catch {
            // reason 要能留痕读出:不加 privacy: .public 会被脱敏成 <private>。
            editRepositorySheetViewLog.error(
                "event=update_default_branch_failed reason=\(error.localizedDescription, privacy: .public)"
            )
            feedback = CCSpaceFeedback(
                style: .error,
                message: "默认分支写入失败：\(UserFacingError.message(for: error))"
            )
            // 写盘失败时不再更新本地状态:否则本次会话 chip 显示新分支、Store 里仍是旧值,
            // 与"写入失败"红条自相矛盾(下次打开弹窗 onAppear 会用 Store 值重建)。
            return
        }
        // repository 是打开弹窗时的快照,默认分支必须写入本地状态才能反映到 chip/建议行。
        effectiveDefaultBranch = branch
        reorderSuggestions(withDefault: branch)
        if editingMRBranches.isEmpty {
            editingMRBranches = [branch]
        }
    }

    @MainActor
    private func loadRemoteBranchSuggestions(for gitURL: String) async {
        isLoadingRemoteBranches = true
        defer { isLoadingRemoteBranches = false }
        let branches = await infoService.remoteBranches(for: gitURL)
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
            // 换过地址后探测到的默认分支必须随保存落盘:不落盘的话,预览用的
            // 新地址默认分支与 Store 里旧地址的值会长期不一致(MR 目标分支建议
            // 与"当前分支是否默认"都按 Store 值判定)。地址未保存时不写(见
            // previewDefaultBranch 的有意收窄)。
            if let effectiveDefaultBranch, effectiveDefaultBranch != repository.defaultBranch {
                try repositoryStore.updateDefaultBranch(id: repository.id, branch: effectiveDefaultBranch)
            }
            onSaved?()
            dismiss()
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "更新仓库", error: error)
        }
    }
}
