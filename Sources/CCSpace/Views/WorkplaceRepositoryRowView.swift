import SwiftUI

struct WorkplaceRepositoryRowView: View {
    let state: RepositorySyncState
    let repository: RepositoryConfig?
    let displayName: String
    let isPinned: Bool
    let currentBranch: String?
    let branchStatus: GitBranchStatusSnapshot?
    let availableBranches: [String]
    let retryRepository: RepositoryConfig?
    let pullRepository: RepositoryConfig?
    let allowsDeleteRepository: Bool
    let onRetry: (RepositoryConfig) -> Void
    let onRefreshStatus: () -> Void
    let onPull: (RepositoryConfig) -> Void
    let onPush: () -> Void
    let onSwitchBranch: (String) -> Void
    /// 新建分支:第二参为基线分支名(点击行尾 ➕ 所在分支),nil 表示基于当前 HEAD。
    let onCreateBranch: (String, BranchBaseKind) -> Void
    let onDeleteBranch: (String, String?) -> Void
    let onDeleteRemoteBranch: (String) -> Void
    let onSwitchToDefaultBranch: () -> Void
    let onSwitchToWorkBranch: () -> Void
    let showsWorkBranchAction: Bool
    let onMergeDefaultBranchIntoCurrent: () -> Void
    let onCreateMergeRequest: (RepositoryConfig, String?) -> Void
    /// 在浏览器打开仓库主页(右键/⋯ 菜单),URL 解析与失败反馈由宿主协调器承担。
    let onOpenRepositoryWeb: (RepositoryConfig) -> Void
    let actionsDisabled: Bool
    let openActions: [OpenActionItem]
    let preferredOpenAction: OpenActionItem
    let onOpenAction: (OpenActionItem, String) -> Void
    let infoService: RepositoryInfoService
    let onDelete: () -> Void
    let onTogglePinned: () -> Void
    let onStash: () -> Void
    let onPopStash: (Int) -> Void
    let onDropStash: (Int) -> Void
    let onAbortInterruptedOperation: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var showingDeleteConfirmation = false
    /// 删除确认弹窗内容:在删除入口触发时刻做一次目录探测后写入。
    /// 不能按 body 求值现算——此前 .alert 参数直接读计算属性,每帧一次主线程 stat。
    @State private var deleteConfirmation: WorkplaceRepositoryDeleteConfirmationState?
    @State private var isHovered = false
    @State private var showingBranchMenu = false
    /// "菜单收起后弹 popover"的延迟任务句柄,视图消失时取消。
    @State private var popoverPresentationTask: Task<Void, Never>?
    @State private var remoteBranches: [String]?
    @State private var isLoadingRemoteBranches = false
    @State private var remoteBranchesTask: Task<Void, Never>?
    /// 远端分支加载代际号:关闭取消与迟到回写只作用于当前代际,防旧任务打断新任务。
    @State private var remoteBranchesGeneration = 0
    /// 分支面板行内角标数据(最后提交时间 / 领先落后),弹窗打开时加载。
    @State private var branchMetadata: [String: GitBranchMetadata] = [:]
    @State private var branchMetadataTask: Task<Void, Never>?
    /// 与 remoteBranchesGeneration 同款代际号:`Task.isCancelled` 通过后、落笔前,
    /// 新任务可能已启动并写了更新的值——只有代际相等才允许覆盖。
    @State private var branchMetadataGeneration = 0
    @State private var showingStashList = false
    @State private var stashEntries: [GitStashEntry] = []
    @State private var stashGeneration = 0
    @State private var isLoadingStash = false
    @State private var stashTask: Task<Void, Never>?
    @State private var stashError: String?
    @State private var stashDropCandidate: GitStashEntry?
    @State private var showingConflictList = false
    @State private var showingAbortConfirmation = false
    @State private var isErrorExpanded = false
    /// 删除分支的确认候选。确认弹窗由行承载而非分支 popover 内(见下方 alert 注释)。
    @State private var branchDeleteCandidate: BranchDeleteCandidate?

    private var presentationState: WorkplaceRepositoryRowPresentationState {
        WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: retryRepository != nil,
            hasPullRepository: pullRepository != nil,
            allowsDeleteRepository: allowsDeleteRepository,
            actionsDisabled: actionsDisabled,
            hasUncommittedChanges: branchStatus?.hasUncommittedChanges,
            hasConflicts: branchStatus?.hasConflicts
        )
    }

    /// 行内是否处于冲突态(状态快照已知)。
    private var hasConflicts: Bool {
        branchStatus?.hasConflicts ?? false
    }

    /// "中止…"菜单项与确认弹窗共用的文案状态。
    private var abortConfirmationState: WorkplaceRepositoryAbortConfirmationState {
        WorkplaceRepositoryAbortConfirmationState(operation: branchStatus?.interruptedOperation)
    }

    /// "Stash 改动"菜单的 hover 提示;按不可用原因区分说明。
    private var stashMenuHelp: String {
        if actionsDisabled {
            return "仓库操作进行中，暂不可 Stash"
        }
        guard let branchStatus else {
            return "正在读取仓库状态，稍后可用"
        }
        return branchStatus.hasUncommittedChanges
            ? "保存当前未提交改动(含新文件)到 Stash 栈"
            : "当前没有未提交改动，无需 Stash"
    }

    /// "查看改动"菜单的 hover 提示;按不可用原因区分说明。
    private var viewChangesMenuHelp: String {
        if actionsDisabled {
            return "仓库操作进行中，暂不可查看"
        }
        guard let branchStatus else {
            return "正在读取仓库状态，稍后可用"
        }
        return branchStatus.hasUncommittedChanges
            ? "查看未提交改动的 Diff"
            : "当前没有未提交改动"
    }

    /// 「领先 N 个」pill 的点击动作;不可推送(操作进行中等)时返回 nil,pill 退化为纯展示。
    private var pushPillAction: (() -> Void)? {
        presentationState.canPushToRemote ? { onPush() } : nil
    }

    /// 「落后 N 个」pill 的点击动作;不可拉取时返回 nil,pill 退化为纯展示。
    /// 与工具栏 Pull 按钮同一套可用性守卫与动作。
    private var pullPillAction: (() -> Void)? {
        guard presentationState.canPullLatest, let pullRepository else { return nil }
        return { onPull(pullRepository) }
    }

    /// 分支面板 popover 是否可打开:面板除本地分支外还有远端分支与新建分支入口,
    /// 只要有切换权限且存在本地分支即可。
    private var branchMenuDisabled: Bool {
        !presentationState.canSwitchBranch || availableBranches.isEmpty
    }

    /// 分支名 pill 的 hover 提示；禁用时说明不可切换的原因。
    private var branchMenuHelp: String {
        if !presentationState.canSwitchBranch {
            return state.hasLocalDirectory ? "仓库操作进行中，暂不可切换分支" : "仓库尚未克隆，暂不可切换分支"
        }
        if availableBranches.isEmpty {
            return "当前分支，暂无可切换的本地分支"
        }
        return "当前分支，点击可切换本地/远端分支或新建分支"
    }

    private var branchPillState: WorkplaceRepositoryBranchPillState? {
        WorkplaceRepositoryBranchPillState(
            currentBranch: currentBranch,
            defaultBranch: repository?.defaultBranch,
            hasAvailableBranches: availableBranches.isEmpty == false
        )
    }

    private var showsPrimaryActionMenuItems: Bool {
        (state.status == .failed && retryRepository != nil) ||
        (state.status == .success && pullRepository != nil && state.hasLocalDirectory) ||
        presentationState.canOpenLocalActions
    }

    var body: some View {
        // 行内展示状态在 body 顶部求值一次,沿渲染路径复用(与详情页同款模式)。
        // 命名 rowState:存储属性 state 已被 RepositorySyncState 占用,不能遮蔽。
        let rowState = presentationState
        return CCSpaceInteractiveCard(selected: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Button {
                        onTogglePinned()
                    } label: {
                        Group {
                            if isPinned {
                                Image(systemName: isHovered ? "pin.slash" : "pin.fill")
                            } else {
                                Image(systemName: "pin")
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    }
                    .buttonStyle(.plain)
                    .opacity(isPinned || isHovered ? 1 : 0)
                    .accessibilityLabel(isPinned ? "取消置顶" : "置顶仓库")

                    HStack(alignment: .center, spacing: 8) {
                        Text(displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                            // 双击手势只挂在仓库名上,不再罩住整张卡片:
                            // 此前整卡的双倍 tap 会与行内按钮(Pull/提交记录/打开方式…)
                            // 的手势竞争,双击按钮时可能顺带弹出分支面板。
                            .onTapGesture(count: 2) {
                                guard branchMenuDisabled == false else { return }
                                showingBranchMenu = true
                            }
                        if let branchPillState {
                            Button {
                                if branchMenuDisabled == false {
                                    showingBranchMenu = true
                                }
                            } label: {
                                RepositoryBranchPill(
                                    title: branchPillState.title,
                                    isDefault: branchPillState.isDefault,
                                    size: .prominent
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(branchMenuDisabled)
                            .ccspaceQuickHelp(branchMenuHelp)
                            .ccspacePopover(isPresented: $showingBranchMenu, arrowEdge: .top) {
                                BranchListPopoverView(
                                    currentBranch: currentBranch,
                                    localBranches: availableBranches,
                                    remoteBranchNames: remoteBranches,
                                    isLoadingRemoteBranches: isLoadingRemoteBranches,
                                    canSwitchBranch: rowState.canSwitchBranch,
                                    onSwitchBranch: { branch in
                                        // 面板已由弹窗内容经环境入口同步直关(见 CCSpacePopover),
                                        // 此处写 binding 仅作兑底同步;仍保持先关后派发的顺序。
                                        showingBranchMenu = false
                                        onSwitchBranch(branch)
                                    },
                                    onCreateBranch: { branch, base in
                                        // 同 onSwitchBranch:直关已发生,兑底同步后派发。
                                        showingBranchMenu = false
                                        onCreateBranch(branch, base)
                                    },
                                    // 删除分支保持弹窗打开:操作完成后列表随分支快照刷新,
                                    // 被删分支从列表消失(与 Stash 列表行为一致)。
                                    onDeleteBranch: onDeleteBranch,
                                    onDeleteRemoteBranch: onDeleteRemoteBranch,
                                    branchMetadata: branchMetadata,
                                    defaultBranch: repository?.defaultBranch?
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                    onLoadBranchMetadata: loadBranchMetadata,
                                    onRequestDeleteConfirmation: { candidate in
                                        branchDeleteCandidate = candidate
                                    },
                                    onLoadRemoteBranches: loadRemoteBranches,
                                    onCancelRemoteBranches: {
                                        remoteBranchesTask?.cancel()
                                        remoteBranchesTask = nil
                                        // 代际作废:旧任务的迟到回写不再触碰加载态/名单。
                                        remoteBranchesGeneration += 1
                                        // 取消加载后复位加载态:否则再次打开弹窗时
                                        // isLoadingRemoteBranches 卡在 true,列表永远显示加载中。
                                        isLoadingRemoteBranches = false
                                    }
                                )
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        RepositoryBranchStatusView(
                            syncStatus: state.status,
                            branchStatus: branchStatus,
                            showingConflictList: $showingConflictList,
                            onUncommittedTap: { presentWorkingDirectoryDiff() },
                            onConflictsTap: { showingConflictList = true },
                            onPushTap: pushPillAction,
                            onPullTap: pullPillAction
                        ) {
                            ConflictListPopoverView(
                                repositoryName: displayName,
                                unmergedPaths: branchStatus?.unmergedPaths ?? [],
                                interruptedOperation: branchStatus?.interruptedOperation,
                                actionsDisabled: actionsDisabled,
                                onRequestAbort: {
                                    showingAbortConfirmation = true
                                }
                            )
                        }

                        if state.status == .failed, let retryRepository {
                            Button {
                                onRetry(retryRepository)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .ccspaceIconActionButton()
                            .disabled(!rowState.canRetryClone)
                            .ccspaceQuickHelp("重新克隆", providesLabel: true)
                        }

                        if let pullRepository, state.status == .success, state.hasLocalDirectory {
                            Button {
                                onPull(pullRepository)
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .ccspaceIconActionButton()
                            .disabled(!rowState.canPullLatest)
                            .ccspaceQuickHelp("Pull 最新代码", providesLabel: true)
                        }

                        if rowState.canOpenLocalActions {
                            if let repository {
                                if repository.mrTargetBranches.count > 1 {
                                    Menu {
                                        mrTargetBranchMenuItems(repository: repository)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                    // borderlessButton 的 Menu 由 NSButton 渲染标签,会无视
                                    // .foregroundStyle(.secondary) 而呈现黑色,与单目标分支时的
                                    // Button 形态(浅灰)不一致;buttonStyle(.plain) 下标签由
                                    // SwiftUI 渲染,颜色/字号与 ccspaceIconActionButton 对齐
                                    .buttonStyle(.plain)
                                    .menuIndicator(.hidden)
                                    .controlSize(.small)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                                    .disabled(!rowState.canCreateMergeRequest)
                                    .ccspaceQuickHelp("选择 MR 目标分支，可在设置中配置")
                                } else {
                                    Button {
                                        let targetBranch = repository.mrTargetBranches.first
                                        onCreateMergeRequest(repository, targetBranch)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                    .ccspaceIconActionButton()
                                    .disabled(!rowState.canCreateMergeRequest)
                                    .ccspaceQuickHelp(repository.mrTargetBranches.first.map { "向 \($0) 创建 MR，可在设置中配置目标分支" } ?? "向默认分支创建 MR，可在设置中配置目标分支")
                                }
                            }

                        Button {
                            openCommitLogWindow()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .ccspaceIconActionButton()
                        .ccspaceQuickHelp("查看提交记录", providesLabel: true)

                        Button {
                            openBranchCompareWindow()
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .ccspaceIconActionButton()
                        .ccspaceQuickHelp("分支比较", providesLabel: true)

                        Menu {
                            ForEach(openActions) { action in
                                    Button {
                                        onOpenAction(action, state.localPath)
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
                                    .frame(width: 12, height: 12)
                            } primaryAction: {
                                onOpenAction(preferredOpenAction, state.localPath)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .ccspaceQuickHelp("在 \(preferredOpenAction.displayName) 中打开")
                        }

                        Menu {
                            // 与右键菜单同理:macOS 26 默认不渲染 SF Symbol 图标。
                            actionMenuContent(rowState: rowState)
                                .labelStyle(.titleAndIcon)
                        } label: {
                            RepositoryOverflowMenuLabel()
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .ccspaceQuickHelp("更多操作", providesLabel: true)
                    }
                }

                if let lastError = rowState.visibleErrorMessage {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(isErrorExpanded ? nil : 2)
                        .truncationMode(.tail)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isErrorExpanded.toggle()
                            }
                        }
                        .textSelection(.enabled)
                }
            }
        }
        // 双击打开分支面板的手势挂在仓库名上(见 displayName),不挂整张卡片。
        .onHover { isHovered = $0 }
        .contextMenu {
            // macOS 26 右键菜单默认不渲染 Label 的 SF Symbol 图标,显式要求标题+图标。
            actionMenuContent(rowState: rowState)
                .labelStyle(.titleAndIcon)
        }
        .alert(
            deleteConfirmation?.title ?? "",
            isPresented: $showingDeleteConfirmation
        ) {
            Button(deleteConfirmation?.confirmLabel ?? "确认删除", role: .destructive) {
                onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteConfirmation?.message ?? "")
        }
        .alert(
            abortConfirmationState.title,
            isPresented: $showingAbortConfirmation
        ) {
            Button(abortConfirmationState.confirmLabel, role: .destructive) {
                showingConflictList = false
                onAbortInterruptedOperation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(abortConfirmationState.message)
        }
        // 抽成 modifier:整个 body 已很长,再内联一个带 switch 的 alert 会让
        // 类型检查超时("unable to type-check this expression in reasonable time")。
        .modifier(
            BranchDeleteConfirmationModifier(
                candidate: $branchDeleteCandidate,
                onDeleteBranch: onDeleteBranch,
                onDeleteRemoteBranch: onDeleteRemoteBranch
            )
        )
        .ccspacePopover(isPresented: $showingStashList) {
            StashListPopoverView(
                repositoryName: displayName,
                entries: stashEntries,
                isLoading: isLoadingStash,
                error: stashError,
                actionsDisabled: actionsDisabled,
                onRetry: loadStashList,
                onPop: { index in
                    onPopStash(index)
                },
                onRequestDrop: { entry in
                    stashDropCandidate = entry
                }
            )
        }
        // 确认弹窗挂在**行**上而不是 popover 内:popover 是 transient,焦点转移
        // (alert 弹出本身就是一次焦点切换)会把 popover 连带关闭,alert 随之消失,
        // 甚至出现"点了取消但删除仍被执行"的窗口期。与 showingAbortConfirmation 一致。
        .alert(
            stashDropConfirmationTitle,
            isPresented: stashDropConfirmationBinding
        ) {
            Button("删除", role: .destructive) {
                let candidate = stashDropCandidate
                stashDropCandidate = nil
                if let candidate {
                    onDropStash(candidate.index)
                }
            }
            Button("取消", role: .cancel) {
                stashDropCandidate = nil
            }
        } message: {
            Text("删除该 Stash 后不可恢复。")
        }
        .onChange(of: actionsDisabled) { _, isLocked in
            // 恢复/删除 Stash 等操作完成解锁后,若 Stash 列表仍打开则刷新列表。
            if isLocked == false {
                if showingStashList {
                    loadStashList()
                }
                // 删除远端分支等联网操作完成后,分支面板若停在远端页签则重载,让被删分支消失。
                if showingBranchMenu, remoteBranches != nil {
                    loadRemoteBranches()
                }
                // 切分支/合并完成后角标数据(领先落后/时间)已变化,弹窗开着就一并刷新。
                if showingBranchMenu {
                    loadBranchMetadata()
                }
            }
        }
        .onDisappear {
            remoteBranchesTask?.cancel()
            remoteBranchesTask = nil
            branchMetadataTask?.cancel()
            branchMetadataTask = nil
            stashTask?.cancel()
            stashTask = nil
            popoverPresentationTask?.cancel()
            popoverPresentationTask = nil
        }
    }

    private var stashDropConfirmationTitle: String {
        stashDropCandidate.map { "删除 \($0.ref)" } ?? "删除 Stash"
    }

    private var stashDropConfirmationBinding: Binding<Bool> {
        Binding(
            get: { stashDropCandidate != nil },
            set: { isPresented in
                if isPresented == false {
                    stashDropCandidate = nil
                }
            }
        )
    }

    /// 菜单收起动画结束后再弹 popover:过早呈现会被系统丢弃。
    /// 延迟任务持句柄,可在视图消失时取消,避免对已销毁行的迟到状态写入。
    private func presentPopoverAfterMenuDismissal(_ present: @escaping @MainActor () -> Void) {
        popoverPresentationTask?.cancel()
        popoverPresentationTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            popoverPresentationTask = nil
            present()
        }
    }

    /// 打开提交记录独立窗口(与 Diff 窗口同模式,浏览与操作在窗口内自持)。
    private func openCommitLogWindow() {
        openWindow(value: CommitLogWindowPayload(
            repositoryName: displayName,
            localPath: state.localPath
        ))
    }

    /// 打开分支比较独立窗口:初始为"默认分支 → 当前分支",两侧均可再切换。
    private func openBranchCompareWindow() {
        openWindow(value: BranchCompareWindowPayload(
            repositoryName: displayName,
            localPath: state.localPath,
            base: repository?.defaultBranch,
            head: currentBranch
        ))
    }

    /// popover 打开时按需加载远端分支;关闭时取消。
    /// 远端分支名单加载:缓存优先 + 后台刷新(stale-while-revalidate)。
    /// 上一次的名单保留展示,后台 ls-remote 刷新,回来后原位替换——
    /// 此前每次打开弹窗都清空重拉,远端页签要么白屏等网络、要么加载态
    /// 与列表互相顶,网络慢时体验为"特别慢且没有加载动画"。
    /// 首次(无缓存)才显示整块加载态;刷新中的指示在 header 的刷新按钮位置。
    private func loadRemoteBranches() {
        guard presentationState.canSwitchBranch else { return }
        guard state.hasLocalDirectory else { return }
        remoteBranchesTask?.cancel()
        remoteBranchesTask = nil
        remoteBranchesGeneration += 1
        // 不清空旧名单:有缓存就先展示旧数据,刷新回来后原位替换(见函数注释)。
        isLoadingRemoteBranches = true
        let generation = remoteBranchesGeneration
        let localPath = state.localPath
        let configuredURL = repository?.gitURL
        let infoService = infoService
        remoteBranchesTask = Task {
            let branches = await infoService.remoteBranchSuggestions(localPath: localPath, configuredURL: configuredURL)
            guard !Task.isCancelled else {
                // 被取消也要复位加载态:isLoadingRemoteBranches 已置 true,
                // 不复位会让下次打开的弹窗卡在加载指示上。
                // 但只在本任务仍是当前代际时复位:旧任务迟到清理若把新任务
                // 刚置的 true 打回 false,远端页签会短暂显示"空列表+重试"。
                await MainActor.run {
                    if generation == remoteBranchesGeneration {
                        isLoadingRemoteBranches = false
                    }
                }
                return
            }
            // 归一(去重+本地化排序)在后台做一次:分支多时排序可观,
            // 且展示状态每次 body 求值都会消费名单,不能放到主线程现算。
            // (本方法是 View 上的 nonisolated 函数,Task 在首个 await 恢复后
            // 已回到全局并发执行器,不在主线程——此前误判过一轮,勿再"修"成 detached。)
            let normalized = branches.map(BranchListNormalization.remoteBranches)
            await MainActor.run {
                guard generation == remoteBranchesGeneration else { return }
                remoteBranches = normalized
                isLoadingRemoteBranches = false
            }
        }
    }

    /// popover 打开时按需加载分支元数据(时间/领先落后角标);失败静默,行内不展示角标即可。
    private func loadBranchMetadata() {
        branchMetadataTask?.cancel()
        branchMetadataGeneration += 1
        let generation = branchMetadataGeneration
        let localPath = state.localPath
        let infoService = infoService
        branchMetadataTask = Task {
            guard let metadata = await infoService.branchMetadata(localPath: localPath) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == branchMetadataGeneration else { return }
                branchMetadata = metadata
            }
        }
    }

    private func loadStashList() {
        stashTask?.cancel()
        stashGeneration += 1
        let generation = stashGeneration
        isLoadingStash = true
        stashError = nil
        let localPath = state.localPath
        let infoService = infoService
        stashTask = Task {
            guard let entries = await infoService.stashList(localPath: localPath) else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == stashGeneration else { return }
                    stashError = "本地目录不存在：\(localPath)"
                    isLoadingStash = false
                }
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == stashGeneration else { return }
                stashEntries = entries
                isLoadingStash = false
            }
        }
    }

    /// 在独立窗口中打开工作区未提交改动的 diff。
    private func presentWorkingDirectoryDiff() {
        openDiffWindow(
            title: "未提交改动",
            source: .workingDirectory
        )
    }

    /// 打开(或聚焦已打开的)diff 独立窗口;加载与刷新由窗口自持。
    private func openDiffWindow(title: String, source: DiffWindowPayload.Source) {
        openWindow(value: DiffWindowPayload(
            repositoryName: displayName,
            localPath: state.localPath,
            title: title,
            source: source
        ))
    }

    @ViewBuilder
    private func mrTargetBranchMenuItems(repository: RepositoryConfig) -> some View {
        ForEach(repository.mrTargetBranches, id: \.self) { branch in
            Button {
                onCreateMergeRequest(repository, branch)
            } label: {
                // 默认分支用星标前置标记,不再带文字后缀;空白占位图与 star 同尺寸,
                // 图标列等宽保证分支名对齐。macOS 26 菜单默认隐图标,显式 titleAndIcon。
                Label {
                    Text(branch == currentBranch ? "\(branch)（当前分支）" : branch)
                } icon: {
                    Image(nsImage: branch == repository.defaultBranch ? MenuPlaceholderIcon.star : MenuPlaceholderIcon.blank)
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    /// 菜单内容(溢出菜单与右键菜单共用)是展示状态的最重消费者,
    /// 由调用方(body)求值一次后传入,不在内部逐项重建 presentationState。
    /// 参数命名 rowState:函数内仍需访问存储属性 state(RepositorySyncState),不能遮蔽。
    @ViewBuilder
    private func actionMenuContent(
        rowState: WorkplaceRepositoryRowPresentationState
    ) -> some View {
        Button {
            onTogglePinned()
        } label: {
            Label(
                isPinned ? "取消置顶" : "置顶仓库",
                systemImage: isPinned ? "pin.slash" : "pin"
            )
        }
        Divider()
        if let retryRepository, state.status == .failed {
            Button {
                onRetry(retryRepository)
            } label: {
                Label("重新克隆", systemImage: "arrow.clockwise")
            }
            .disabled(!rowState.canRetryClone)
        }
        if rowState.canOpenLocalActions {
            Button {
                onRefreshStatus()
            } label: {
                Label("刷新仓库状态", systemImage: "arrow.clockwise")
            }
            .disabled(!rowState.canRefreshStatus)
        }
        if let pullRepository, state.status == .success, state.hasLocalDirectory {
            Button {
                onPull(pullRepository)
            } label: {
                Label("Pull 最新代码", systemImage: "square.and.arrow.down")
            }
            .disabled(!rowState.canPullLatest)
        }
        if rowState.canOpenLocalActions {
            Button {
                onPush()
            } label: {
                Label("Push 到远端", systemImage: "square.and.arrow.up")
            }
            .disabled(!rowState.canPushToRemote)
            Divider()
            Button {
                presentPopoverAfterMenuDismissal { showingBranchMenu = true }
            } label: {
                Label("切换分支…", systemImage: "arrow.triangle.branch")
            }
            .disabled(branchMenuDisabled)
            .ccspaceQuickHelp("打开分支面板：本地/远端分支、搜索与新建分支")
            Button {
                onSwitchToDefaultBranch()
            } label: {
                Label("切到默认分支", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(!rowState.canSwitchBranch)
            if showsWorkBranchAction {
                Button {
                    onSwitchToWorkBranch()
                } label: {
                    Label("切到工作分支", systemImage: "hammer.circle")
                }
                .disabled(!rowState.canSwitchBranch)
            }
            Button {
                onMergeDefaultBranchIntoCurrent()
            } label: {
                Label("合并默认分支到当前分支", systemImage: "arrow.triangle.merge")
            }
            .disabled(!rowState.canSwitchBranch)
            if let repository {
                if repository.mrTargetBranches.count > 1 {
                    Menu {
                        mrTargetBranchMenuItems(repository: repository)
                    } label: {
                        Label("创建 MR", systemImage: "arrow.up.right.square")
                    }
                    .disabled(!rowState.canCreateMergeRequest)
                } else {
                    Button {
                        let targetBranch = repository.mrTargetBranches.first
                        onCreateMergeRequest(repository, targetBranch)
                    } label: {
                        Label(
                            repository.mrTargetBranches.first.map { "向 \($0) 创建 MR" } ?? "向默认分支创建 MR",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .disabled(!rowState.canCreateMergeRequest)
                }
            }
            // 打开仓库主页只依赖配置的远端地址,不要求本地目录存在,
            // 故放在 canOpenLocalActions 块之外,与 MR 同属"网页"动作组。
            if let repository {
                Button {
                    onOpenRepositoryWeb(repository)
                } label: {
                    Label("在浏览器打开仓库", systemImage: "globe")
                }
                .ccspaceQuickHelp("打开该仓库的网页主页")
            }
            Divider()
            ForEach(openActions) { action in
                Button {
                    onOpenAction(action, state.localPath)
                } label: {
                    Label {
                        Text(action.displayName)
                    } icon: {
                        Image(nsImage: action.icon)
                    }
                }
            }
            Divider()
            Button {
                openCommitLogWindow()
            } label: {
                Label("查看提交记录", systemImage: "clock.arrow.circlepath")
            }
            Button {
                openBranchCompareWindow()
            } label: {
                Label("分支比较", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!rowState.canOpenLocalActions)
            .ccspaceQuickHelp("打开分支比较窗口：默认分支与当前分支的差异")
            if rowState.canOpenLocalActions {
                Button {
                    presentWorkingDirectoryDiff()
                } label: {
                    Label("查看改动", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(!rowState.canViewChanges)
                .ccspaceQuickHelp(viewChangesMenuHelp)
                Divider()
                Button {
                    onStash()
                } label: {
                    Label("Stash 改动", systemImage: "archivebox")
                }
                .disabled(!rowState.canStashChanges)
                .ccspaceQuickHelp(stashMenuHelp)
                Button {
                    presentPopoverAfterMenuDismissal {
                        loadStashList()
                        showingStashList = true
                    }
                } label: {
                    Label("Stash 列表…", systemImage: "tray.full")
                }
            }
            if hasConflicts {
                Divider()
                Button(role: .destructive) {
                    showingAbortConfirmation = true
                } label: {
                    Label(abortConfirmationState.title, systemImage: "arrow.uturn.backward.circle.slash")
                }
                .disabled(!rowState.canAbortInterruptedOperation)
                .ccspaceQuickHelp("丢弃进行中的操作与冲突解决，回到操作前的状态")
                Button {
                    showingConflictList = true
                } label: {
                    Label("查看冲突文件…", systemImage: "exclamationmark.triangle")
                }
                .ccspaceQuickHelp("查看冲突文件列表，或中止进行中的操作")
            }
        }
        if showsPrimaryActionMenuItems {
            Divider()
        }
        Button(role: .destructive) {
            // 目录探测收敛到触发时刻,每次点击只 stat 一次,body 路径零 IO。
            deleteConfirmation = WorkplaceRepositoryDeleteConfirmationState(
                repositoryName: displayName,
                localPath: state.localPath,
                directoryPath: existingDirectoryPath(state.localPath)
            )
            showingDeleteConfirmation = true
        } label: {
            Label("删除仓库", systemImage: "trash")
        }
        .disabled(!rowState.canDeleteRepository)
    }
}

struct RepositoryBranchPill: View {
    let title: String
    let isDefault: Bool
    /// 左侧分支图标开关:标题栏胶囊场景(提交记录/分支比较)分支名已自说明,
    /// 图标会让文字与左圆弧的间隙明显大于右侧,由调用方关闭。
    let showsIcon: Bool
    /// 尺寸档:仓库行用 `.prominent`(字/图标/内边距整体放大一档),
    /// 标题栏与设置页保持 `.compact` 原规格——几处版式各自定稿过,不连带变化。
    enum Size {
        case compact
        case prominent
    }
    let size: Size

    init(title: String, isDefault: Bool = false, showsIcon: Bool = true, size: Size = .compact) {
        self.title = title
        self.isDefault = isDefault
        self.showsIcon = showsIcon
        self.size = size
    }

    @State private var isHovering = false

    private var tint: Color { isDefault ? .orange : .accentColor }
    private var icon: String { isDefault ? "star.fill" : "arrow.triangle.branch" }

    var body: some View {
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: icon)
                    .font(.system(size: size == .prominent ? 8 : 7))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(size == .prominent ? .caption : .caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, size == .prominent ? 8 : 6)
        .padding(.vertical, size == .prominent ? 3 : 2)
        .background(tint.opacity(isHovering ? 0.18 : 0.1), in: Capsule())
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct RepositoryOverflowMenuLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var foregroundColor: Color {
        guard isEnabled else { return Color.secondary.opacity(0.42) }
        return isHovering ? .primary : .secondary
    }

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(foregroundColor)
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
            .opacity(isHovering && isEnabled ? 0.92 : 0.68)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel("更多操作")
    }
}

private struct RepositoryBranchStatusView<ConflictPopover: View>: View {
    let syncStatus: SyncStatus
    let branchStatus: GitBranchStatusSnapshot?
    /// 冲突弹窗锚在冲突 pill 上(而非整行),弹出位置与入口对齐。
    @Binding var showingConflictList: Bool
    var onUncommittedTap: (() -> Void)? = nil
    var onConflictsTap: (() -> Void)? = nil
    var onPushTap: (() -> Void)? = nil
    var onPullTap: (() -> Void)? = nil
    @ViewBuilder var conflictPopover: () -> ConflictPopover

    var body: some View {
        let summary = RepositoryBranchStatusSummary(
            syncStatus: syncStatus,
            branchStatus: branchStatus
        )

        Group {
            if let activityTitle = summary.activityTitle {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(activityTitle)
                }
                .font(.caption)
                .foregroundStyle(summary.activityTint)
                .accessibilityLabel("状态：\(activityTitle)")
            } else if summary.showsShimmer {
                CCSpaceShimmerPill()
                    .accessibilityLabel("状态加载中")
            } else {
                HStack(spacing: 4) {
                    ForEach(summary.pills) { pill in
                        let pillView = RepositoryBranchStatePill(
                            title: pill.title,
                            tint: pill.tint,
                            quickHelp: pill.quickHelp,
                            action: action(for: pill)
                        )
                        if pill.action == .viewConflicts {
                            pillView
                                .ccspacePopover(isPresented: $showingConflictList) {
                                    conflictPopover()
                                }
                        } else {
                            pillView
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "分支状态：\(summary.pills.map(\.effectiveAccessibilityTitle).joined(separator: "，"))"
                )
            }
        }
    }

    /// pill 动作对应的回调;对应回调为 nil(如操作进行中)时 pill 退化为纯展示。
    private func action(for pill: RepositoryBranchStatePillModel) -> (() -> Void)? {
        switch pill.action {
        case .viewUncommitted: return onUncommittedTap
        case .viewConflicts: return onConflictsTap
        case .push: return onPushTap
        case .pull: return onPullTap
        case nil: return nil
        }
    }
}

struct RepositoryBranchStatusSummary {
    let syncStatus: SyncStatus
    let branchStatus: GitBranchStatusSnapshot?

    var activityTitle: String? {
        syncStatus.activityTitle
    }

    var activityTint: Color {
        syncStatus.activityTint
    }

    var showsShimmer: Bool {
        branchStatus == nil && syncStatus == .success
    }

    var pills: [RepositoryBranchStatePillModel] {
        if let branchStatus {
            var pills: [RepositoryBranchStatePillModel] = []
            if branchStatus.hasConflicts {
                // 冲突是"未提交"的子集且更紧急:此时不再展示"未提交" pill,避免两个
                // 都可点但语义重叠的入口并列。
                pills.append(.init(
                    title: "冲突 \(branchStatus.conflictCount) 个",
                    tint: .red,
                    quickHelp: "点击查看冲突文件并中止操作",
                    action: .viewConflicts,
                    accessibilityTitle: "存在 \(branchStatus.conflictCount) 个冲突文件"
                ))
            } else if branchStatus.hasUncommittedChanges {
                pills.append(.init(
                    title: "未提交",
                    tint: .orange,
                    quickHelp: "点击查看改动",
                    action: .viewUncommitted
                ))
            }
            if branchStatus.hasUnpushedCommits {
                pills.append(.init(
                    title: "领先 \(branchStatus.aheadCount) 个",
                    tint: .blue,
                    quickHelp: "领先远端 \(branchStatus.aheadCount) 个提交，点击推送",
                    action: .push,
                    accessibilityTitle: "未推送 \(branchStatus.aheadCount) 个提交"
                ))
            }
            if branchStatus.isBehindRemote {
                pills.append(.init(
                    title: "落后 \(branchStatus.behindCount) 个",
                    tint: .orange,
                    quickHelp: "落后远端 \(branchStatus.behindCount) 个提交，点击拉取",
                    action: .pull,
                    accessibilityTitle: "落后远端 \(branchStatus.behindCount) 个提交"
                ))
            }
            if branchStatus.hasRemoteTrackingBranch == false {
                pills.append(.init(
                    title: "未关联远端",
                    tint: .secondary,
                    quickHelp: "点击推送并关联远端",
                    action: .push
                ))
            }
            if pills.isEmpty {
                pills.append(.init(title: "干净", tint: .green, quickHelp: "没有未提交或未推送的变更"))
            }
            return pills
        }

        switch syncStatus {
        case .idle:
            return [.init(title: "未克隆", tint: .secondary, quickHelp: "仓库尚未克隆到本地")]
        case .failed:
            return [.init(title: "异常", tint: .red, quickHelp: "上次操作失败，可尝试重试")]
        case .success:
            return [.init(title: "状态未知", tint: .secondary, quickHelp: nil)]
        case .cloning, .pulling, .switching, .removing:
            return []
        }
    }
}

enum PillTint {
    case red, orange, blue, green, secondary

    var foreground: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .green: .green
        case .secondary: .secondary
        }
    }

    var background: Color {
        switch self {
        case .red: Color.red.opacity(0.10)
        case .orange: Color.orange.opacity(0.10)
        case .blue: Color.blue.opacity(0.10)
        case .green: Color.green.opacity(0.10)
        case .secondary: Color.primary.opacity(0.035)
        }
    }
}

struct RepositoryBranchStatePillModel: Identifiable {
    /// pill 点击触发的动作;nil 为纯展示。
    enum Action {
        case viewUncommitted
        case viewConflicts
        case push
        case pull
    }

    let title: String
    let tint: PillTint
    let quickHelp: String?
    var action: Action? = nil
    /// 供 VoiceOver 朗读的完整文案；缩写式 pill 标题(如"领先 2 个")朗读时需展开为完整语义。
    var accessibilityTitle: String? = nil

    var isActionable: Bool { action != nil }

    var id: String { title }

    var effectiveAccessibilityTitle: String {
        accessibilityTitle ?? title
    }
}

private struct RepositoryBranchStatePill: View {
    let title: String
    let tint: PillTint
    var quickHelp: String? = nil
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                pillLabel
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .ccspaceQuickHelp(quickHelp ?? "点击查看改动")
        } else {
            pillLabel
                .ccspaceQuickHelp(quickHelp)
        }
    }

    private var pillLabel: some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                isHovering ? tint.background.opacity(0.7) : tint.background,
                in: Capsule()
            )
            .foregroundStyle(tint.foreground)
            .overlay(
                Capsule()
                    .strokeBorder(tint.foreground.opacity(isHovering ? 0.4 : 0), lineWidth: 1)
            )
    }
}

private extension SyncStatus {
    var activityTitle: String? {
        switch self {
        case .idle:
            return nil
        case .cloning:
            return "克隆中"
        case .pulling:
            return "同步中"
        case .switching:
            return "切换中"
        case .success:
            return nil
        case .failed:
            return nil
        case .removing:
            return "移除中"
        }
    }

    var activityTint: Color {
        switch self {
        case .cloning, .removing:
            return .orange
        case .pulling, .switching:
            return .blue
        case .idle, .success, .failed:
            return .secondary
        }
    }
}

/// 删除分支确认弹窗,由**行**承载而不是分支 popover 内部:
/// popover 是 transient behavior,alert 弹出时的焦点切换会把 popover 连带关闭,
/// alert 随之消失,甚至出现"点了取消但删除仍被执行"的窗口期。删除分支不可恢复,
/// 确认必须挂在稳定的宿主视图上(与 Stash 删除确认、中断操作确认一致)。
/// internal 并供 BranchSwitchPopoverView 的无宿主回退路径复用:
/// 此前 popover 内部维护着逐行复制的同款 alert,两处行为被迫人工同步。
struct BranchDeleteConfirmationModifier: ViewModifier {
    @Binding var candidate: BranchDeleteCandidate?
    let onDeleteBranch: (String, String?) -> Void
    let onDeleteRemoteBranch: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(
            candidate?.alertTitle ?? "删除分支",
            isPresented: presentedBinding
        ) {
            buttons
        } message: {
            Text(candidate?.alertMessage ?? "")
        }
    }

    private var presentedBinding: Binding<Bool> {
        Binding(
            get: { candidate != nil },
            set: { isPresented in
                if isPresented == false {
                    candidate = nil
                }
            }
        )
    }

    @ViewBuilder
    private var buttons: some View {
        switch candidate {
        case .local(let branch, let remoteBranch):
            if let remoteBranch {
                Button("仅删除本地分支", role: .destructive) {
                    onDeleteBranch(branch, nil)
                    candidate = nil
                }
                Button("同时删除 origin/\(remoteBranch)", role: .destructive) {
                    onDeleteBranch(branch, remoteBranch)
                    candidate = nil
                }
            } else {
                Button("删除", role: .destructive) {
                    onDeleteBranch(branch, nil)
                    candidate = nil
                }
            }
        case .remote(let branch, _):
            Button("删除", role: .destructive) {
                onDeleteRemoteBranch(branch)
                candidate = nil
            }
        case nil:
            Button("删除", role: .destructive) {
                candidate = nil
            }
        }
        Button("取消", role: .cancel) {
            candidate = nil
        }
    }
}
