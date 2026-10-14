import SwiftUI
import AppKit
import os
import UniformTypeIdentifiers

private let repositoryConfigViewLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RepositorySettingsSection"
)

struct RepositorySettingsSection: View {
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    /// 搜索词由 SettingsView 持有:仓库区与同页「回到顶部」共用同一份。
    @Binding var searchText: String
    /// 仓库区只读信息查询(默认分支探测、MR 分支名单):提升为存储属性,
    /// 避免在 body 每次求值时重建一份。
    private let infoService: RepositoryInfoService
    /// 把某条仓库行滚进视野:由 SettingsView 注入(它才持有外层 ScrollView 的 reader)。
    let scrollToRepository: (UUID) -> Void
    /// 新增仓库专用的地址框:与 `searchText` 是两个互不相干的控件——
    /// 地址框只负责建档,搜索框只负责过滤,粘贴地址不再把列表筛成"未找到"。
    @State private var addURLText = ""
    /// 点过「新增仓库」但框里是空的:提示行要说"没填",不能报"格式不对"。
    @State private var addSubmitAttempted = false
    @FocusState private var addURLFocused: Bool
    @State private var feedback: CCSpaceFeedback?
    @State private var deletePresentationState: RepositoryDeletePresentationState?
    /// 刚新增成功的仓库:行高亮一小段时间,配合滚动定位让用户看见它加在哪儿了。
    @State private var justAddedRepositoryID: UUID?
    @State private var justAddedResetTask: Task<Void, Never>?
    /// MR 目标分支面板的状态(开在哪一行 / 远端名单 / 加载态 / 探测代际)。
    /// 四者必须同进同退,故收在 `MRBranchPanelState` 里由它自己守住不变式。
    @State private var mrPanel = MRBranchPanelState()
    /// 在途的 `ls-remote`:连同它属于哪一次呈现一起记账。取消只允许针对同一次呈现,
    /// 否则旧面板迟到的 `onDisappear` 会把新面板刚起的探测打成"探测失败"。
    @State private var mrRemoteProbe: (session: MRBranchPanelState.Session, task: Task<Void, Never>)?
    /// 在途的默认分支补探。它不在面板状态机里(一次性的旁路写盘),但同样必须记账:
    /// 任务强引用 `RepositoryStore`,主窗口关闭→重开会换一个新 store 实例,这条没归宿
    /// 的任务会以**旧实例的内存快照**整库回写,把期间删掉的仓库复活。
    @State private var defaultBranchProbeTask: Task<Void, Never>?
    /// 补探代际:`Task.isCancelled` 通过后、落笔前仍可能被新的补探取代,与 mrPanel 同用令牌兜住。
    @State private var defaultBranchProbeSequence = 0

    init(
        repositoryStore: RepositoryStore,
        workplaceStore: WorkplaceStore,
        gitService: GitServicing,
        searchText: Binding<String>,
        scrollToRepository: @escaping (UUID) -> Void
    ) {
        self.repositoryStore = repositoryStore
        self.workplaceStore = workplaceStore
        self.gitService = gitService
        self._searchText = searchText
        self.scrollToRepository = scrollToRepository
        infoService = RepositoryInfoService(gitService: gitService)
    }

    private var repositories: [RepositoryConfig] {
        repositoryStore.repositories.sorted {
            $0.repoName.localizedStandardCompare($1.repoName) == .orderedAscending
        }
    }

    private func exportRepositoriesBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "导出 Git 仓库备份"
        panel.message = "请输入备份文件名并选择保存位置"
        panel.nameFieldStringValue = RepositoryBackupExportPresentationState.defaultFileName()
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = try repositoryStore.exportBackup(to: url)
            feedback = RepositoryConfigFeedbackFactory.exportSuccess(
                repositoryCount: document.repositories.count
            )
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "导出仓库备份",
                error: error
            )
        }
    }

    private func importRepositoriesBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try repositoryStore.importBackup(from: url)
            feedback = RepositoryConfigFeedbackFactory.importResult(result)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "导入仓库备份",
                error: error
            )
        }
    }

    var body: some View {
        // repositories 是每次访问全量重排的计算属性,一次 body 求值会被触发多次:
        // 顶部取一次局部值,搜索展示状态也只构建一份沿渲染路径复用。
        let repositories = self.repositories
        let searchState = RepositorySearchPresentationState(
            repositories: repositories,
            searchText: searchText
        )
        return VStack(alignment: .leading, spacing: 12) {
            headerSection

            if let shownFeedback = feedback {
                CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { self.feedback = nil })
                    .ccspaceAutoDismissFeedback($feedback)
            }

            // 地址框(含提示行)在上,搜索框在下:两个入口不共用一个控件。
            addRepositoryRow

            // 仓库池为空时搜索框没有可过滤的内容,不出现;新增引导由地址框承担。
            if repositories.isEmpty == false {
                searchField
            }

            if searchState.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: searchState.emptyTitle,
                    subtitle: searchState.emptySubtitle,
                    systemImage: repositories.isEmpty ? "shippingbox" : "magnifyingglass"
                ) {
                    EmptyView()
                }
            } else {
                // 仓库列表全量平铺,随设置页整体滚动,不再固定高度内部滚动。
                repositoryList(searchState)
            }

        }
        .alert(
            deletePresentationState?.title ?? "",
            isPresented: Binding(
                get: { deletePresentationState != nil },
                set: { isPresented in
                    if isPresented == false {
                        deletePresentationState = nil
                    }
                }
            )
        ) {
            if let deletePresentationState, deletePresentationState.isBlocked == false {
                Button(deletePresentationState.confirmLabel, role: .destructive) {
                    confirmDeleteRepository()
                }
                Button("取消", role: .cancel) {}
            } else {
                Button("知道了", role: .cancel) {}
            }
        } message: {
            Text(deletePresentationState?.message ?? "")
        }
        .onChange(of: justAddedRepositoryID) { _, repositoryID in
            guard let repositoryID,
                  searchState.filteredRepositories.count <= RepositoryListLayout.eagerRowLimit else { return }
            // 新行是这一轮才插进列表的,同帧 scrollTo 还找不到锚点:等下一次主循环再做。
            Task { @MainActor in
                scrollToRepository(repositoryID)
            }
        }
        .onChange(of: addURLText) { _, newValue in
            // 框被清空回"没输入"时,上一轮的"请先粘贴"必须退场,否则会挂成常驻红字。
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addSubmitAttempted = false
            }
        }
        .onDisappear {
            // 离开设置页:高亮定时器与在途探测都没有归宿了,别留着空转的 Task 持有状态箱。
            justAddedResetTask?.cancel()
            justAddedResetTask = nil
            justAddedRepositoryID = nil
            cancelAllRemoteProbes()
            defaultBranchProbeTask?.cancel()
            defaultBranchProbeTask = nil
            defaultBranchProbeSequence += 1
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索仓库名称或地址", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 地址框 + 框外实心蓝按钮。下方那一行只在该有话说时插入(格式错/已存在/将创建预览),
    /// 空框时不留占位行——两个输入框之间默认就是普通间距。
    private var addRepositoryRow: some View {
        let hint = addHint
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                addURLField
                addRepositoryButton
            }
            if hint.text.isEmpty == false {
                addHintLine(hint)
            }
        }
    }

    /// 白底 + 浅描边,与灰底搜索框一眼分开;聚焦只加深描边灰度,不上蓝色焦点环
    /// (设置页通篇没有彩色边框)。
    private var addURLField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("粘贴 Git 仓库地址", text: $addURLText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($addURLFocused)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(addURLFocused ? 0.22 : 0.10),
                    lineWidth: 1
                )
        }
    }

    private var addRepositoryButton: some View {
        Button {
            addRepository()
        } label: {
            Label("新增仓库", systemImage: "plus")
        }
        .ccspacePrimaryActionButton()
        .ccspaceQuickHelp("以地址框的内容新增仓库")
    }

    private var addHint: RepositoryAddFieldHint {
        RepositoryAddFieldHint(
            gitURL: addURLText,
            submitAttempted: addSubmitAttempted,
            repositories: repositoryStore.repositories
        )
    }

    @ViewBuilder
    private func addHintLine(_ hint: RepositoryAddFieldHint) -> some View {
        HStack(spacing: 6) {
            Text(hint.text)
                .font(.caption)
                .foregroundStyle(hintColor(for: hint.style))
            if let duplicateRepositoryID = hint.duplicateRepositoryID {
                Button("定位") {
                    locateRepository(duplicateRepositoryID)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func hintColor(for style: RepositoryAddFieldHint.Style) -> Color {
        switch style {
        case .neutral: Color.secondary
        case .duplicate: .orange
        case .error: .red
        }
    }

    /// 点击时才判定,按钮不置灰。拦截性反馈一律落在地址框下方那一行,不再占用
    /// 区块顶部横幅——顶部只留"已新增 xxx"和写盘失败这类整页级信息。
    private func addRepository() {
        let gitURL = addURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gitURL.isEmpty == false else {
            addSubmitAttempted = true
            addURLFocused = true
            return
        }
        // 格式与重复都已在提示行里说清了,这里只需挡住提交:再去 store 撞一次异常,
        // 只会得到同一条信息的第二个版本(顶部红条)。
        let hint = addHint
        guard hint.style != .error, hint.duplicateRepositoryID == nil else {
            addURLFocused = true
            return
        }
        do {
            let repository = try repositoryStore.addRepository(gitURL: gitURL)
            addURLText = ""
            addSubmitAttempted = false
            clearSearchIfOccluding(repository)
            feedback = RepositoryConfigFeedbackFactory.addSuccess(repositoryName: repository.repoName)
            flagJustAdded(repository.id)
            refreshDefaultBranch(id: repository.id, gitURL: repository.gitURL)
            // 连续新增:焦点留在地址框,下一个直接 ⌘V。
            addURLFocused = true
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "新增仓库", error: error)
        }
    }

    /// 搜索词还挂着、而这条记录不匹配它时先把词清掉——否则用户看不见刚加的仓库
    /// (判据与列表过滤同源,见 `RepositorySearchPresentationState.matches`)。
    private func clearSearchIfOccluding(_ repository: RepositoryConfig) {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyword.isEmpty == false,
              RepositorySearchPresentationState.matches(repository, keyword: keyword) == false else { return }
        searchText = ""
    }

    /// 从提示行跳到已建档的那一行:同一判据先保证它没被搜索词滤掉,再滚过去。
    private func locateRepository(_ id: UUID) {
        if let repository = repositoryStore.repository(for: id) {
            clearSearchIfOccluding(repository)
        }
        // 刚清过词,这一轮列表才重排;同帧 scrollTo 可能找不到锚点,跳一拍再做。
        Task { @MainActor in
            scrollToRepository(id)
        }
    }

    /// 新增后定位并高亮那一行:高亮 2.4s 自动退场;滚动等下一次渲染再做
    /// (行是这一轮才插进列表的,同帧 scrollTo 找不到锚点)。
    private func flagJustAdded(_ id: UUID) {
        justAddedResetTask?.cancel()
        justAddedRepositoryID = id
        justAddedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2_400))
            // 只清自己点亮的这次高亮:连点两次新增时前一个定时器可能已经醒来排在主队列上,
            // cancel() 拦不住已入队的续体,会把后一次的高亮提前抹掉。
            guard !Task.isCancelled, justAddedRepositoryID == id else { return }
            justAddedRepositoryID = nil
        }
    }

    /// 按行的面板开关绑定:点外部/Esc 关闭时 SwiftUI 回写 false,与按钮的开合走同一收口。
    private func mrPanelBinding(for repository: RepositoryConfig) -> Binding<Bool> {
        Binding(
            get: { mrPanel.isOpen(for: repository.id) },
            set: { presented in
                if presented {
                    mrPanel.open(repositoryID: repository.id)
                } else {
                    closeMREditor(repositoryID: repository.id)
                }
            }
        )
    }

    private func toggleMREditor(for repository: RepositoryConfig) {
        if mrPanel.isOpen(for: repository.id) {
            closeMREditor(repositoryID: repository.id)
        } else {
            mrPanel.open(repositoryID: repository.id)
        }
    }

    /// 关闭:先取回这一行的归属快照,状态机与在途任务一起按它收口(归属判定见 MRBranchPanelState)。
    private func closeMREditor(repositoryID: UUID) {
        let session = mrPanel.sessionToken(for: repositoryID)
        mrPanel.close(repositoryID: repositoryID)
        // 取不到归属说明面板早已换到别的行了,这一行没有在途任务要收口。此时**不能**按
        // nil 全量取消:那会正好作废新面板刚发起的探测,而任务体在 `Task.isCancelled`
        // 处直接返回、不会 `finishLoad`,加载态永远停在 true(转圈且没有重试入口)。
        if let session {
            cancelRemoteProbe(matching: session)
        }
    }

    /// 面板内容消失时作废在途探测:传的是它自己那次呈现的快照,不是行 ID。
    private func cancelMRPanelLoad(session: MRBranchPanelState.Session?) {
        mrPanel.cancelLoad(session)
        if let session {
            cancelRemoteProbe(matching: session)
        }
    }

    /// cancel 只为省一次网络请求(拦迟到写回的是代际令牌),因此只允许针对**同一次呈现**。
    private func cancelRemoteProbe(matching session: MRBranchPanelState.Session) {
        guard let probe = mrRemoteProbe, probe.session == session else { return }
        probe.task.cancel()
        mrRemoteProbe = nil
    }

    /// 整块视图消失(离开设置页)时的全量收口:此时不存在"别的面板还在用"。
    private func cancelAllRemoteProbes() {
        mrRemoteProbe?.task.cancel()
        mrRemoteProbe = nil
    }

    /// 面板打开与点刷新时拉远端名单(`ls-remote`)。
    /// 归一(去重+trim+本地化排序)不能省:不排序的话同一仓库在设置面板里是 git 的
    /// 原始 ref 顺序、在工作区分支面板里是本地化顺序;分支多时排序也不能留在主线程。
    private func loadRemoteBranches(session: MRBranchPanelState.Session?, gitURL: String) {
        guard let session, let generation = mrPanel.beginLoad(session) else { return }
        cancelRemoteProbe(matching: session)
        let infoService = infoService
        mrRemoteProbe = (
            session: session,
            task: Task { @MainActor in
                let probed = await infoService.remoteBranches(for: gitURL)
                let normalized: [String]?
                if let probed {
                    normalized = await Task.detached(priority: .userInitiated) {
                        BranchListNormalization.remoteBranches(probed)
                    }.value
                } else {
                    normalized = nil
                }
                // 被取消说明这次呈现已被取代(且取消路径会把结果打成 nil,即"探测失败"):
                // 直接丢弃,别让旧面板把新面板的名单收口成空。
                guard !Task.isCancelled else { return }
                mrPanel.finishLoad(session, generation: generation, branches: normalized)
                // 默认分支只在建档那一刻探一次,离线/超时就没有第二次机会(编辑弹窗已删,
                // 再没有别的写入口)。用户既然打开了这个仓库的面板,顺手补探一次。
                if normalized != nil {
                    refreshDefaultBranch(id: session.repositoryID, gitURL: gitURL)
                }
            }
        )
    }

    /// 面板里点一条:已加过的移除、没加过的追加。名单以 Store 实时值为基准——
    /// 面板保持打开,闭包捕获的行快照从第二次点击起就是旧的。
    private func toggleMRBranch(repository: RepositoryConfig, branch: String) {
        guard let current = repositoryStore.repository(for: repository.id) else { return }
        writeMRBranches(
            current: current,
            branches: MRBranchToggle.nextBranches(current: current.mrTargetBranches, toggled: branch)
        )
    }

    /// 写盘唯一出口:值没变就不写(空写一遍会把 updatedAt 刷脏并触发整库落盘)。
    private func writeMRBranches(current: RepositoryConfig, branches: [String]) {
        guard current.mrTargetBranches != branches else { return }
        do {
            try repositoryStore.updateMRTargetBranches(id: current.id, branches: branches)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(action: "更新 MR 目标分支", error: error)
        }
    }

    /// 补探测并回写默认分支:行上的「默认分支」胶囊、MR 面板的默认分支保护与工作区
    /// 行的 MR 兜底都依赖这个值。探测/写盘失败都静默(不打扰主流程,下次开面板再补)。
    private func refreshDefaultBranch(id: UUID, gitURL: String) {
        // 已有值就不发这次请求:这里是"补空",不是"纠正"。
        let recorded = repositoryStore.repository(for: id)
        guard let recorded,
              (recorded.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
            return
        }
        let infoService = infoService
        let repositoryStore = repositoryStore
        defaultBranchProbeTask?.cancel()
        defaultBranchProbeSequence += 1
        let token = defaultBranchProbeSequence
        defaultBranchProbeTask = Task { @MainActor in
            let probeResult = await infoService.defaultBranch(for: gitURL)
            // 令牌与取消双闸:视图已消失/已被新一次补探取代时不得再碰 store——
            // 那可能已是上一个窗口实例的内存快照,整库回写会复活期间删掉的仓库。
            guard !Task.isCancelled, token == defaultBranchProbeSequence else { return }
            // 探测期间记录可能被改(换地址/删库/导入合并写了值),按回来后的实时值再判一次。
            let current = repositoryStore.repository(for: id)
            let branch = DefaultBranchWriteDecision.branchToWrite(
                probeResult: probeResult,
                recordedGitURL: current?.gitURL,
                recordedDefaultBranch: current?.defaultBranch,
                probedGitURL: gitURL
            )
            guard let branch else { return }
            do {
                try repositoryStore.updateDefaultBranch(id: id, branch: branch)
            } catch {
                // reason 不标 .public 会被日志脱敏成 <private>,读不出成因。
                repositoryConfigViewLog.error(
                    "event=refresh_default_branch_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func repositoryList(_ searchState: RepositorySearchPresentationState) -> some View {
        // 见 `RepositoryListLayout.eagerRowLimit`:默认全量建行,`scrollTo` 才保证找得到锚点。
        Group {
            if searchState.filteredRepositories.count > RepositoryListLayout.eagerRowLimit {
                LazyVStack(spacing: RepositoryListLayout.rowSpacing) {
                    repositoryRows(searchState.filteredRepositories)
                }
            } else {
                VStack(spacing: RepositoryListLayout.rowSpacing) {
                    repositoryRows(searchState.filteredRepositories)
                }
            }
        }
    }

    private func repositoryRows(_ repositories: [RepositoryConfig]) -> some View {
        ForEach(repositories) { repository in
            repositoryRow(repository)
                // scrollTo 只认显式 .id 的锚点,ForEach 自身的 Identifiable 身份不算。
                .id(repository.id)
        }
    }

    private var headerSection: some View {
        // 区块头只留标题+副标题:仓库计数不再展示。
        // 导入/导出是**整个仓库区**的备份动作,不属于「新增」这一操作,故置于区块头右侧:
        // 有仓库/空列表两种状态下位置完全一致,操作区只剩搜索+新增仓库。
        // 与副标题行对齐(.lastTextBaseline):贴标题显得偏高,压到副标题这条线上视觉重心才稳。
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "在此添加的仓库可在创建工作区时直接勾选。"
            )

            Spacer(minLength: 12)

            backupActionButtons
        }
    }

    /// 导入/导出不再收进「更多」菜单,作为可见按钮呈现。
    /// 空列表没有可备份的内容,导出置灰,避免导出一份空 JSON。
    private var backupActionButtons: some View {
        Group {
            Button("导入") {
                importRepositoriesBackup()
            }
            .ccspaceSecondaryActionButton()
            .ccspaceQuickHelp("从 JSON 文件导入仓库配置")

            Button("导出") {
                exportRepositoriesBackup()
            }
            .ccspaceSecondaryActionButton()
            .disabled(repositoryStore.repositories.isEmpty)
            .ccspaceQuickHelp("将当前仓库配置导出为 JSON 备份")
        }
    }

    @ViewBuilder
    private func repositoryRow(_ repository: RepositoryConfig) -> some View {
        let isJustAdded = justAddedRepositoryID == repository.id
        CCSpaceInteractiveCard(selected: isJustAdded) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(repository.repoName)
                            .font(.body.weight(.medium))

                        if let defaultBranch = repository.defaultBranch {
                            RepositoryBranchPill(title: defaultBranch, isDefault: true, showsIcon: false)
                                .ccspaceQuickHelp("默认分支")
                        }

                        // MR 目标分支与默认分支同一行,单行平铺、超出折叠为「+N」;
                        // 默认分支已由上面那颗橙色胶囊表达,这里再画一遍就是重复信息。
                        // 胶囊只读:增删统一在「添加 MR 目标分支」面板里点选完成。
                        let mrOnlyBranches = MRBranchChipDisplay.visibleBranches(
                            branches: repository.mrTargetBranches,
                            defaultBranch: repository.defaultBranch
                        )
                        if mrOnlyBranches.isEmpty == false {
                            MRBranchChips(branches: mrOnlyBranches)
                        }
                    }

                    Text(repository.gitURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                // 三个操作按钮收紧密度(2pt)+ 放大一档(28pt 框):
                // 与仓库行的行内按钮簇同款"贴排"口径。
                HStack(spacing: 2) {
                    Button {
                        openRepositoryWeb(repository)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .ccspaceIconActionButton(large: true)
                    .ccspaceQuickHelp("在浏览器打开仓库", providesLabel: true)

                    // 原「编辑仓库地址」位置换成 MR 目标分支入口:点开工作区仓库行同款的
                    // 分支面板(远端名单 + 搜索),点行即增删,面板保持打开可连续配置。
                    // 图标沿用全 app 的 MR 记号;不用 arrow.triangle.branch——
                    // 那颗在菜单里已经表示"切换分支"。
                    Button {
                        toggleMREditor(for: repository)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .ccspaceIconActionButton(large: true)
                    .ccspaceQuickHelp("添加 MR 目标分支", providesLabel: true)
                    .accessibilityLabel("添加 MR 目标分支")
                    .ccspacePopover(isPresented: mrPanelBinding(for: repository), arrowEdge: .top) {
                        // 归属快照在呈现时刻取一次,随闭包带走(见 MRBranchPanelState.Session)。
                        let panelSession = mrPanel.sessionToken(for: repository.id)
                        BranchListPopoverView(
                            remoteBranchNames: mrPanel.remoteBranches,
                            isLoadingRemoteBranches: mrPanel.isLoadingRemoteBranches,
                            selectedBranches: repository.mrTargetBranches,
                            pickHint: "点击添加或移除 MR 目标分支",
                            onToggleBranch: { branch in
                                toggleMRBranch(repository: repository, branch: branch)
                            },
                            onLoadRemoteBranches: {
                                loadRemoteBranches(session: panelSession, gitURL: repository.gitURL)
                            },
                            onCancelRemoteBranches: { cancelMRPanelLoad(session: panelSession) }
                        )
                    }

                    Button(role: .destructive) {
                        prepareDelete(repository)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .ccspaceIconActionButton(large: true)
                    .ccspaceQuickHelp("删除仓库", providesLabel: true)
                }
            }
        }
        // 刚新增的行:底色之外再描一圈主色边框,2.4s 后随 justAddedRepositoryID 清空一起退场。
        .overlay {
            if isJustAdded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isJustAdded)
    }

    private func removeRepository(_ id: UUID) {
        let repositoryName = repositoryStore.repositories.first { $0.id == id }?.repoName
        do {
            try repositoryStore.removeRepository(id: id, workplaceStore: workplaceStore)
            if let repositoryName {
                feedback = RepositoryConfigFeedbackFactory.deleteSuccess(repositoryName: repositoryName)
            } else {
                feedback = nil
            }
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "删除仓库",
                error: error
            )
        }
    }

    private func prepareDelete(_ repository: RepositoryConfig) {
        deletePresentationState = RepositoryDeletePresentationState(
            repository: repository,
            workplaces: workplaceStore.workplaces
        )
    }

    /// 在浏览器打开仓库主页:按配置的远端地址生成链接,失败弹本区反馈。
    private func openRepositoryWeb(_ repository: RepositoryConfig) {
        do {
            let url = try GitURLParser.repositoryWebURL(from: repository.gitURL)
            try WorkplaceSystemActions.openInBrowser(url)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "打开仓库主页",
                error: error
            )
        }
    }

    private func confirmDeleteRepository() {
        guard let repositoryID = deletePresentationState?.repositoryID else { return }
        deletePresentationState = nil
        removeRepository(repositoryID)
    }
}

/// MR 目标分支胶囊:**单行只读**展示,超出阈值折叠为「+N」(悬停逐条列出)。
/// 默认分支由仓库行那颗橙色「默认分支」胶囊表达,调用方已把它从列表里滤掉;
/// 增删一律在「添加 MR 分支」面板里点选完成,胶囊本身不带任何操作。
struct MRBranchChips: View {
    let branches: [String]

    var body: some View {
        let group = RepositoryBranchPillGroupPresentationState(branches: branches)
        HStack(spacing: 6) {
            ForEach(group.visibleBranches, id: \.self) { branch in
                Text(branch)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    // 胶囊会被中间截断,hover 同时给"这是什么"和完整分支名。
                    .ccspaceQuickHelp("MR 目标分支：\(branch)")
            }
            if let overflowCountText = group.overflowCountText {
                RepositoryBranchPill(title: overflowCountText)
                    .ccspaceQuickHelp(group.overflowQuickHelpText ?? "MR 目标分支")
            }
        }
    }
}
