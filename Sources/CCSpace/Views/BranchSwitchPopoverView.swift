import SwiftUI

/// 分支列表弹窗:切换/对比/多选共用同一骨架,行一律展示裸名(对比模式裸名撞车时保留前缀)。
/// 回调值口径:对比模式上抛可直接给 git 的跟踪引用(origin/x),多选点选即时上抛且面板不关。
struct BranchListPopoverView: View {
    enum Mode {
        case switchBranch
        case compare
        case multiPick
    }

    /// 弹窗同步直关入口:pick/新建类回调先直关面板再上抛宿主。
    /// binding 回写跨窗口、与派发动作的状态写入同帧竞争,面板会间歇性关不掉。
    @Environment(\.ccspacePopoverDismiss) private var dismissPopover

    let mode: Mode
    let currentBranch: String?
    let localBranches: [String]
    /// 切换模式:远端裸分支名(nil 表示尚未加载);对比模式:本地跟踪分支(带前缀)。
    let remoteBranches: [String]?
    let isLoadingRemoteBranches: Bool
    let canSwitchBranch: Bool
    /// 对比模式收到可直接交给 git 的跟踪引用(`origin/x`):值就是 ref,只在展示层去前缀。
    let onPick: (String) -> Void
    /// 新建分支:第一参为新分支名,第二参为基线(点击行尾 ➕ 所在的那条分支,
    /// 本地页签收 `.localBranch(裸名)`,远端页签收 `.remoteBranch(裸名)`)。
    let onCreateBranch: ((String, BranchBaseKind) -> Void)?
    /// 删除本地分支(切换模式本地页签提供),第二参为需连带删除的远端同名分支(裸名,nil 只删本地);
    /// 对比模式无删除入口,为 nil。
    let onDeleteBranch: ((String, String?) -> Void)?
    /// 删除远端分支(切换模式远端页签提供,收还原后的裸名);对比模式为 nil。
    let onDeleteRemoteBranch: ((String) -> Void)?
    /// 以当前分支为源向指定裸名目标分支创建 MR;nil(对比模式/无宿主入口)时行内不提供按钮。
    var onCreateMergeRequestForBranch: ((String) -> Void)? = nil
    var branchMetadata: [String: GitBranchMetadata] = [:]
    /// 仓库默认分支(裸名,如 main):远端页签该行是保护分支,不提供删除入口。
    var defaultBranch: String? = nil
    /// 非切换模式的行点击提示:文案随复用用途由各自便捷 init 注入。
    var pickHint: String = ""
    /// 多选模式:当前已配置的分支(裸名);行据此打勾,点选在宿主侧增删。
    var selectedBranches: [String] = []
    /// 弹窗出现时加载分支元数据(与 onLoadRemoteBranches 同一时机)。
    var onLoadBranchMetadata: (() -> Void)? = nil
    /// 删除确认上抛给宿主承载:transient popover 会被 alert 弹出的焦点切换连带关闭,
    /// 删除分支不可恢复,确认必须由宿主(行/窗口)弹。
    var onRequestDeleteConfirmation: ((BranchDeleteCandidate) -> Void)? = nil
    let onLoadRemoteBranches: () -> Void
    let onCancelRemoteBranches: () -> Void

    @State private var source: BranchSwitchListSource = .local
    /// 当前生效的页签:`source` 初值改不动(成员式 init 由 SwiftUI 生成,统一 `.local`),
    /// onAppear 改写又晚于首帧——首帧会渲染出空的本地名单;所有读取走这里屏蔽那一帧。
    private var effectiveSource: BranchSwitchListSource {
        mode == .multiPick ? .remote : source
    }
    @State private var searchText = ""
    @State private var copiedBranch: String?
    @State private var creatingFromBranch: String?
    /// orderedLocalBranches 的排序 memo。
    @State private var orderedLocalBranchesMemo = OrderedLocalBranchesMemo()

    /// 弹窗内容的统一横向留白:header 与行共用同一常量,左右逐像素相等。
    /// 原生 List 给行施加左右不相等的系统浮动边距(实测前导 10~25pt),永远对不齐,故自绘列表。
    private static let contentHorizontalInset: CGFloat = 12

    /// 远端名单要不要联网拉:对比模式的"远端"是本地跟踪分支,本就在仓库里,无需加载。
    private var loadsRemoteFromNetwork: Bool { mode != .compare }

    /// 切换/多选模式专用:远端独有分支(裸名)。
    private var remotePresentation: BranchSwitchRemotePresentationState {
        BranchSwitchRemotePresentationState(remoteBranches: remoteBranches)
    }

    /// 本地页签展示顺序:按最近活动排序(元数据未到达时保持字母序原样)。
    /// 搜索每个按键都触发 body 重算,全量排序在大仓库是可观的主线程开销——输入不变则复用缓存。
    private var orderedLocalBranches: [String] {
        let memo = orderedLocalBranchesMemo
        if memo.cachedBranches == localBranches, memo.cachedMetadata == branchMetadata {
            return memo.result
        }
        let sorted = BranchActivityOrder.sorted(localBranches, metadata: branchMetadata)
        memo.cachedBranches = localBranches
        memo.cachedMetadata = branchMetadata
        memo.result = sorted
        return sorted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            listSection
        }
        // 宽度固定:弹窗尺寸不随名单变化;长名截断策略见 BranchNameDisplay。
        .frame(width: BranchNameDisplay.fixedPopoverWidth)
        .onAppear {
            onLoadBranchMetadata?()
            onLoadRemoteBranches()
        }
        .onDisappear {
            onCancelRemoteBranches()
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            // 多选模式没有本地名单,只画"远端"一段。
            BranchSourceTabBar(
                selection: Binding(get: { effectiveSource }, set: { source = $0 }),
                showsLocalTab: mode != .multiPick
            )

            // 远端列表来自 ls-remote 缓存,不刷新看不到他人新推的分支。
            if loadsRemoteFromNetwork, effectiveSource == .remote {
                if isLoadingRemoteBranches {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Button(action: onLoadRemoteBranches) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .ccspaceQuickHelp("重新获取远端分支", providesLabel: true)
                    .accessibilityLabel("重新获取远端分支")
                }
            }

            // 放大镜/清空按钮因 cell 图标不占文本位、会与占位符重叠,改由 SwiftUI 侧自绘。
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeSearchField(text: $searchText, placeholder: "搜索分支")
                    .frame(height: 20)
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .ccspaceQuickHelp("清空搜索", providesLabel: true)
                    .accessibilityLabel("清空搜索")
                }
            }
            // maxWidth 撑满吃掉页签之外的剩余宽度:胶囊右缘 12+4 与行尾 ➕ 右缘 12+4 落同一条竖线;
            // 不撑满则右缘由 NSSearchField 内在宽度决定,trailing padding 加不加都不动它。
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(branchHeaderGlassCorner(radius: 7))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.contentHorizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onChange(of: source) { _, newValue in
            // onAppear 只在首次出现时触发;切回远端页签仍未加载则补一次。
            if loadsRemoteFromNetwork, newValue == .remote, remoteBranches == nil, isLoadingRemoteBranches == false {
                onLoadRemoteBranches()
            }
        }
    }

    /// 远端展示状态在每次 body 求值中只构建一次再沿行传下去;ForEach 每行各建一份是 O(N²)。
    @ViewBuilder
    private var listSection: some View {
        // 整块加载态只用于"无缓存首发";有缓存时列表照常展示(stale-while-revalidate)。
        if loadsRemoteFromNetwork, effectiveSource == .remote, isLoadingRemoteBranches, remoteBranches == nil {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在加载远端分支…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.contentHorizontalInset)
            .padding(.vertical, 8)
            .frame(height: BranchSwitchListPresentationState.fixedListHeight, alignment: .top)
        } else {
            let remote = remotePresentation
            let state = listPresentationState(remote: remote)
            ScrollView {
                // 必须 LazyVStack:VStack 会在主线程全量实例化所有行,实测 500 分支 1.0s、
                // 2000 分支 5.3s——列表从远端加载回来整个 app 卡死数秒(可见区只有 5 行)。
                LazyVStack(alignment: .leading, spacing: 0) {
                    if state.filteredBranches.isEmpty {
                        listEmptyView(state)
                    } else {
                        branchRows(state.filteredBranches)
                    }
                }
                .padding(.horizontal, Self.contentHorizontalInset)
            }
            .frame(height: BranchSwitchListPresentationState.fixedListHeight)
        }
    }

    private func listPresentationState(
        remote: BranchSwitchRemotePresentationState
    ) -> BranchPopoverListState {
        switch mode {
        case .switchBranch, .multiPick:
            let state = BranchSwitchListPresentationState(
                localBranches: orderedLocalBranches,
                remoteBranchNames: remote.remoteBranchNames,
                source: effectiveSource,
                searchText: searchText
            )
            return BranchPopoverListState(
                filteredBranches: state.filteredBranches,
                emptyTitle: state.emptyTitle,
                emptySubtitle: state.emptySubtitle,
                // 刷新中不提供重试(指示已在 header 转轮)。
                showsRetry: effectiveSource == .remote
                    && remote.remoteBranchNames.isEmpty
                    && isLoadingRemoteBranches == false
            )
        case .compare:
            let state = CompareBranchListPresentationState(
                branches: effectiveSource == .local ? orderedLocalBranches : (remoteBranches ?? []),
                searchText: searchText
            )
            return BranchPopoverListState(
                filteredBranches: state.filteredBranches,
                emptyTitle: state.emptyTitle,
                emptySubtitle: state.emptySubtitle,
                showsRetry: false
            )
        }
    }

    private func branchRows(_ branches: [String]) -> some View {
        // 多选:已添加置顶、其余保序(稳定排序,点选只移动被操作行,不整表乱跳)。
        let rows = mode == .multiPick
            ? BranchSelectionOrder.selectedFirst(branches, selected: selectedBranches)
            : branches
        let rowPickHint = mode == .switchBranch ? "点击切换到该分支" : pickHint
        let showsCreateButton = mode == .switchBranch
        // MR 入口仅切换模式且宿主提供回调时给(提交记录窗口的切换器无宿主回调)。
        let showsMergeRequestButton = mode == .switchBranch && onCreateMergeRequestForBranch != nil
        // 对比模式统一展示裸名,但多 remote 仓库(fork + upstream)会让两行都叫 `main`:
        // 裸名撞车的那几个保留 `remote/` 前缀,否则用户无从分辨要比的是哪一个。
        let ambiguousRemoteBareNames = mode == .compare
            ? BranchRemoteRef.ambiguousBareNames(ofTrackingRefs: branches)
            : []
        let showsBareRemoteNames = mode == .compare && effectiveSource == .remote
        return ForEach(rows, id: \.self) { branch in
            BranchSwitchRow(
                branch: branch,
                displayBranch: BranchRemoteRef.displayBranch(
                    ofTrackingRef: branch,
                    ambiguousBareNames: ambiguousRemoteBareNames,
                    showsBareRemoteNames: showsBareRemoteNames
                ),
                isCurrentBranch: branch == currentBranch,
                copiedBranch: $copiedBranch,
                isDisabled: mode == .multiPick ? false : !canSwitchBranch,
                pickHint: rowPickHint,
                showsSwitchButton: mode == .switchBranch,
                showsCreateButton: showsCreateButton,
                showsMergeRequestButton: showsMergeRequestButton,
                selected: mode == .multiPick && selectedBranches.contains(branch),
                showsSelectionSlot: mode == .multiPick,
                showsCopyButton: mode != .multiPick,
                onDelete: deleteAction(for: branch),
                metadata: effectiveSource == .local ? branchMetadata[branch] : nil
            ) {
                // 多选模式点完不关面板:一次配完多条比"点一条重开一次"省事。
                if mode != .multiPick {
                    dismissPopover()
                }
                onPick(branch)
            } onCreateFromHere: {
                creatingFromBranch = creatingFromBranch == branch ? nil : branch
            } onCreateMergeRequestForBranch: {
                dismissPopover()
                onCreateMergeRequestForBranch?(branch)
            }
            // 输入行插在该分支下方、原行保留(替换会把分支名整个挡掉)。
            if showsCreateButton, creatingFromBranch == branch {
                CreateBranchInlineRow(
                    baseBranch: branch,
                    isDisabled: !canSwitchBranch
                ) { name in
                    dismissPopover()
                    // 基线一律是该行的裸分支名;远端页签标记为远端基线,
                    // Service 层创建前先 fetch 刷新 origin/ 引用。
                    onCreateBranch?(
                        name,
                        effectiveSource == .remote ? .remoteBranch(branch) : .localBranch(branch)
                    )
                    creatingFromBranch = nil
                } onCancel: {
                    creatingFromBranch = nil
                }
            }
        }
    }

    /// 删除入口只在切换模式提供:本地页签删本地(当前分支不给入口;远端已加载且同名可连带),
    /// 远端页签删远端引用(不影响本地检出;默认分支是保护分支不给入口);对比模式无删除。
    private func deleteAction(for branch: String) -> (() -> Void)? {
        guard mode == .switchBranch else { return nil }
        if effectiveSource == .local {
            guard onDeleteBranch != nil else { return nil }
            guard branch != currentBranch else { return nil }
            // 探测远端同名分支:存在则确认弹窗提供"同时删除远端"选项(未加载时不预设远端状态)。
            // 注意用原始 remoteBranches:nil 表示尚未加载,不能经 remotePresentation 折叠成空数组。
            let remoteBranch = remoteBranches?.contains(branch) == true ? branch : nil
            return { requestDeleteConfirmation(.local(branch: branch, remoteBranch: remoteBranch)) }
        }
        guard onDeleteRemoteBranch != nil else { return nil }
        guard branch != defaultBranch else { return nil }
        // 删除是破坏性动作:确认文案仍写全 origin/<分支>,说清删的是远端引用。
        return { requestDeleteConfirmation(.remote(branch: branch, displayName: "origin/\(branch)")) }
    }

    private func requestDeleteConfirmation(_ candidate: BranchDeleteCandidate) {
        onRequestDeleteConfirmation?(candidate)
    }

    private func listEmptyView(_ state: BranchPopoverListState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.emptyTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            if state.emptySubtitle.isEmpty == false {
                Text(state.emptySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            if state.showsRetry {
                Button("重试", action: onLoadRemoteBranches)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

struct BranchPopoverListState {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String
    let showsRetry: Bool
}

/// 待确认的删除目标:均记裸分支名,远端展示名的 origin/ 前缀由文案现算。
/// 远端删除会推送删除引用到服务器、影响所有协作者,确认文案单独强调。
enum BranchDeleteCandidate {
    case local(branch: String, remoteBranch: String?)
    case remote(branch: String, displayName: String)

    var alertTitle: String {
        switch self {
        case .local(let branch, _):
            return "删除分支 \(branch)？"
        case .remote(_, let displayName):
            return "删除远端分支 \(displayName)？"
        }
    }

    var alertMessage: String {
        switch self {
        case .local(_, let remoteBranch):
            if remoteBranch != nil {
                return "删除该分支后不可恢复；检测到远端存在同名分支，可选择一并删除，远端删除影响所有协作者。"
            }
            return "删除该分支后不可恢复。"
        case .remote:
            return "将从远端仓库删除该分支，影响所有协作者。"
        }
    }
}

/// 长分支名的展示策略:区分度集中在尾部,一律优先保尾部。
/// 极端超长名由 displayText 护栏截成"前缀/…尾部",仍放不下时行内 .head 省略 + hover 全名兜底。
enum BranchNameDisplay {
    /// 超长名护栏阈值:超过该字符数才做"前缀/…尾部"预截断。
    static let maxDisplayCharacters = 60

    /// 弹窗固定宽度:所有分支面板(切换/对比/多选)共用这一常量,尺寸不随名单变化。
    static let fixedPopoverWidth: CGFloat = 330

    /// 展示文本:不超过阈值原样返回;超长保留首个"/"前的层级前缀,其余空间给尾部。
    static func displayText(for branch: String) -> String {
        let characters = Array(branch)
        guard characters.count > maxDisplayCharacters else { return branch }
        if let slashIndex = branch.firstIndex(of: "/") {
            let prefix = String(branch[...slashIndex])
            // 前缀本身已占掉大半宽度时不再保留(如 release/2026/… 的深层嵌套)。
            if prefix.count * 2 < maxDisplayCharacters {
                let tailBudget = maxDisplayCharacters - prefix.count - 1 // 1 为省略号
                return prefix + "…" + String(characters.suffix(tailBudget))
            }
        }
        return "…" + String(characters.suffix(maxDisplayCharacters - 1))
    }
}

struct BranchSwitchRow: View {
    let branch: String
    /// 行内展示名与 `branch` 不同时(对比模式的跟踪引用 origin/x),标签/hover 只给裸名,
    /// 复制/回调/删除仍用 `branch` 真值。
    var displayBranch: String? = nil
    let isCurrentBranch: Bool
    @Binding var copiedBranch: String?
    let isDisabled: Bool
    /// 非当前分支行的悬停提示,按模式区分点击语义。
    var pickHint: String? = nil
    /// 整行点击命中区小、容易误触,切换模式额外提供显式"切换到此分支"按钮。
    var showsSwitchButton: Bool = false
    var showsCreateButton: Bool = false
    /// 源分支与目标分支不能相同,当前分支行隐藏建 MR 按钮。
    var showsMergeRequestButton: Bool = false
    /// 多选模式:该行已添加,动作簇首位显示 accent 对勾、分支名跟着加重。
    var selected: Bool = false
    /// 未选中的多选行也占住对勾那一格,否则各行分支名的右缘会差出一格宽度。
    var showsSelectionSlot: Bool = false
    var showsCopyButton: Bool = true
    /// 删除回调;nil(对比模式或不可删的行)时按钮隐藏。
    var onDelete: (() -> Void)? = nil
    /// 分支元数据;nil(远端页签/未加载)时不展示角标。
    var metadata: GitBranchMetadata? = nil
    let onSwitch: () -> Void
    var onCreateFromHere: (() -> Void)? = nil
    var onCreateMergeRequestForBranch: (() -> Void)? = nil
    @State private var resetTask: Task<Void, Never>?
    @State private var isDeleteHovering = false
    @State private var isRowHovering = false

    /// 当前分支行不给常驻底色:它与 hover 灰同色阶会被读成"鼠标停着的那行",
    /// 标识改由行尾的 accent 对勾承担;仅整行可点的行才有 hover 灰底。
    private var rowHoverBackground: Color {
        guard isDisabled == false, isCurrentBranch == false, isRowHovering else { return .clear }
        return Color.primary.opacity(0.06)
    }

    private var label: String { displayBranch ?? branch }

    /// 分支名可能被护栏截断/头部省略,hover 提示始终给全名。
    private var nameHelp: String {
        if isCurrentBranch { return "当前分支：\(label)" }
        guard let pickHint else { return label }
        return "\(label)\n\(pickHint)"
    }

    /// 鼠标点击与读屏默认动作共用同一条守卫,不让两个入口漂移。
    private func handleRowTap() {
        guard isDisabled == false, isCurrentBranch == false else { return }
        onSwitch()
    }

    /// 行内角标:上游已删除警示 / ⇡领先 / ⇣落后 / 相对时间;完整含义在 metadataHelp 悬停给出。
    @ViewBuilder
    private var metadataView: some View {
        if let metadata {
            HStack(spacing: 4) {
                if metadata.upstreamGone {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if metadata.aheadCount > 0 {
                    Text("⇡\(metadata.aheadCount)")
                        .foregroundStyle(.blue)
                }
                if metadata.behindCount > 0 {
                    Text("⇣\(metadata.behindCount)")
                        .foregroundStyle(.orange)
                }
                if let date = metadata.lastCommitDate {
                    Text(date.relativeDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .help(metadataHelp)
        }
    }

    private var metadataHelp: String {
        guard let metadata else { return branch }
        var parts: [String] = [branch]
        if metadata.aheadCount > 0 { parts.append("领先上游 \(metadata.aheadCount) 个提交") }
        if metadata.behindCount > 0 { parts.append("落后上游 \(metadata.behindCount) 个提交") }
        if metadata.upstreamGone { parts.append("上游分支已删除") }
        if let date = metadata.lastCommitDate {
            parts.append("最后提交 \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: "，")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(BranchNameDisplay.displayText(for: label))
                .lineLimit(1)
                .truncationMode(.head)
                // 多选"已选"复用当前分支的半粗+accent 标识(语义都是"这条已经在了")。
                .fontWeight(isCurrentBranch || selected ? .semibold : .regular)
                .foregroundStyle(
                    isCurrentBranch || selected ? Color.accentColor : Color(nsColor: .labelColor)
                )
                // 标识纯视觉化后,读屏也要能拿到"当前分支"语义。
                .accessibilityLabel(
                    isCurrentBranch ? "\(label)，当前分支"
                        : (selected ? "\(label)，已添加" : label)
                )
            Spacer(minLength: 6)
            metadataView
            // 动作簇:图标 20×20 定尺、间距 2,悬停高亮块跨行对齐。
            // 图标一律 label 墨色:.secondary 在切换按钮的 accent 蓝对比下会被读成"状态点缀"而非按钮。
            HStack(spacing: 2) {
                // 当前分支与多选"已添加"把切换按钮这格换成不可点的对勾:样式位置一致,动作簇与邻行同列。
                if (showsSwitchButton && isCurrentBranch) || selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .accessibilityLabel(isCurrentBranch ? "当前分支" : "已添加为 MR 目标分支")
                } else if showsSwitchButton, isDisabled == false {
                    Button(action: onSwitch) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .ccspaceQuickHelp("切换到此分支", providesLabel: true)
                    .accessibilityLabel("切换到此分支")
                } else if showsSelectionSlot {
                    Color.clear.frame(width: 20, height: 20)
                }
                // 建 MR 直接打开网页、不含 Push。
                if showsMergeRequestButton, isCurrentBranch == false {
                    Button(action: { onCreateMergeRequestForBranch?() }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
                    .ccspaceQuickHelp("以当前分支向该分支创建 MR", providesLabel: true)
                    .accessibilityLabel("向该分支创建 MR")
                }
                if showsCopyButton {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(branch, forType: .string)
                        copiedBranch = branch
                        // 取消上一次复位任务,避免旧任务把新复位的 checkmark 提前清掉。
                        resetTask?.cancel()
                        resetTask = Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            copiedBranch = nil
                        }
                    } label: {
                        Image(systemName: copiedBranch == branch ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .ccspaceQuickHelp("复制分支名", providesLabel: true)
                    .accessibilityLabel("复制分支名")
                }
                // 删除分支(可用性由宿主 deleteAction 决定)。
                if onDelete != nil {
                    Button(action: { onDelete?() }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(isDeleteHovering ? Color.red : Color(nsColor: .labelColor))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
                    .onHover { isDeleteHovering = $0 }
                    .ccspaceQuickHelp("删除分支", providesLabel: true)
                    .accessibilityLabel("删除分支")
                }
                // 行尾 ➕ 新建:当前分支行同样提供(不像删除/MR 那样排除)。
                if showsCreateButton {
                    Button(action: { onCreateFromHere?() }) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
                    .ccspaceQuickHelp("基于该分支创建新分支并切换", providesLabel: true)
                    .accessibilityLabel("基于该分支创建新分支")
                }
            }
        }
        // 前导 4pt 内收、尾随 0:行尾 ➕ 的 20×20 按钮框右缘落在容器右缘。
        .padding(.leading, 4)
        .padding(.vertical, 6)
        // 圆角 7pt 取自左栏选中 chip 像素采样;尾随收 2pt(左右缘≈4/2,视觉对称)让灰底包住 ➕ 按钮。
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowHoverBackground)
                .padding(.trailing, 2)
        }
        .contentShape(Rectangle())
        // 悬停提示挂整行:名字右侧的空白处也该能弹出全名;行内按钮悬停时由其自身提示接管
        // (气泡协调器保证同一时刻只有一个)。
        .ccspaceQuickHelp(nameHelp)
        .onTapGesture(perform: handleRowTap)
        // 多选面板的整行是唯一命中区、行内无按钮:只给 onTapGesture 的话键盘与读屏够不着这条唯一入口。
        .modifier(BranchRowPickAction(enabled: showsSelectionSlot, action: handleRowTap))
        .onHover { isRowHovering = $0 }
        .opacity(isDisabled ? 0.5 : 1)
        .onDisappear {
            // 行消失(关闭/过滤/滚动)时先复位 copiedBranch 再取消任务:
            // 只取消不复位会让父级状态悬留,行重新可见后对勾常亮。
            if copiedBranch == branch {
                copiedBranch = nil
            }
            resetTask?.cancel()
            resetTask = nil
        }
    }
}

/// 多选行的读屏/键盘动作:把整行合成一个带按钮语义的元素并挂上默认动作。
/// 只在多选模式启用——那种行内没有任何按钮;切换/对比行一旦合并反而会把按钮从读屏树抹掉。
private struct BranchRowPickAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
        } else {
            content
        }
    }
}

/// "基于该分支新建"的输入行:回车或"创建"以该行分支为基线创建并切换;✕ 收起本行。
struct CreateBranchInlineRow: View {
    let baseBranch: String
    let isDisabled: Bool
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // 行内 4pt 与分支行的行内 padding 同值,外层再叠加容器统一留白 12pt。
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(width: 10)
                TextField("新分支名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .ccspaceQuickHelp("基于 \(baseBranch) 创建并切换")
                Button("创建", action: submit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(trimmedName.isEmpty || isDisabled || validationError != nil)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .ccspaceQuickHelp("取消")
                .accessibilityLabel("取消新建分支")
            }
            // 非法分支名在输入侧就拦下,与新建工作区表单同一校验口径,不甩裸 git 报错给用户。
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .onAppear { isFocused = true }
    }

    /// 输入非空时给出具体错误;为空时返回 nil(空输入由"创建"按钮禁用兜住,不重复报错)。
    private var validationError: String? {
        trimmedName.isEmpty ? nil : BranchNameValidation.validate(trimmedName)
    }

    private func submit() {
        guard trimmedName.isEmpty == false, isDisabled == false, validationError == nil else { return }
        onCreate(trimmedName)
    }
}

/// 玻璃底座:半透明材质 + 内侧高光描边(popover 内没有系统玻璃容器,只能自绘)。
private func branchHeaderGlassCorner(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
        )
}

/// 来源页签:玻璃底座 + 系统侧栏选中色滑块。
/// 不用 NSSegmentedControl(它的 bezel 画不出这套皮肤);弹簧参数与设置页统一。
struct BranchSourceTabBar: View {
    @Binding var selection: BranchSwitchListSource
    /// 多选面板只画"远端"一段,位置与两页签时一致(header 列不变)。
    var showsLocalTab: Bool = true
    @Namespace private var sliderNamespace

    var body: some View {
        HStack(spacing: 2) {
            if showsLocalTab {
                tabButton("本地", for: .local)
            }
            tabButton("远端", for: .remote)
        }
        .padding(2)
        .background(branchHeaderGlassCorner(radius: 8))
        .animation(.spring(response: 0.34, dampingFraction: 0.74), value: selection)
    }

    private func tabButton(_ title: String, for source: BranchSwitchListSource) -> some View {
        Button {
            selection = source
        } label: {
            Text(title)
                .font(.callout)
                .fontWeight(selection == source ? .medium : .regular)
                // 浅色模式"蓝底黑字"根因是 selectedControlTextColor:其配套底色是浅灰(浅色=黑字),
                // 压强调蓝底成黑字。底色不变,文字钉成白色(transient popover 存续期即 key 窗口,白字安全)。
                .foregroundStyle(
                    selection == source
                        ? Color.white
                        : Color.secondary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 2.5)
                .background {
                    if selection == source {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .selectedContentBackgroundColor))
                            .matchedGeometryEffect(id: "branch-tab-slider", in: sliderNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == source ? .isSelected : [])
    }
}

/// 无边框 NSSearchField 只负责输入行为(controlTextDidChange 实时回写、Esc 清空同步)。
/// cell 图标不占文本位、会与占位符重叠,放大镜与清空按钮改由 SwiftUI 侧自绘。
struct NativeSearchField: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String

    init(text: Binding<String>, placeholder: String) {
        _text = text
        self.placeholder = placeholder
    }

    func makeNSView(context: Context) -> EscapeClearSearchField {
        let field = EscapeClearSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textCommitted(_:))
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        return field
    }

    func updateNSView(_ nsView: EscapeClearSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// Enter 与 Esc 清空(cancelOperation 派发的 action)都走这里同步绑定。
        @objc func textCommitted(_ sender: NSSearchField) {
            let value = sender.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }
    }
}

/// Esc 时清空内容并派发 action 的搜索框(原生 cancelOperation 路径)。
final class EscapeClearSearchField: NSSearchField {
    override func cancelOperation(_ sender: Any?) {
        guard stringValue.isEmpty == false else {
            super.cancelOperation(sender)
            return
        }
        stringValue = ""
        if let action {
            sendAction(action, to: target)
        }
    }
}

extension BranchListPopoverView {
    init(
        currentBranch: String?,
        localBranches: [String],
        remoteBranchNames: [String]?,
        isLoadingRemoteBranches: Bool,
        canSwitchBranch: Bool,
        onSwitchBranch: @escaping (String) -> Void,
        onCreateBranch: @escaping (String, BranchBaseKind) -> Void,
        onDeleteBranch: @escaping (String, String?) -> Void,
        onDeleteRemoteBranch: @escaping (String) -> Void,
        onCreateMergeRequestForBranch: ((String) -> Void)? = nil,
        branchMetadata: [String: GitBranchMetadata] = [:],
        defaultBranch: String? = nil,
        onLoadBranchMetadata: (() -> Void)? = nil,
        onRequestDeleteConfirmation: ((BranchDeleteCandidate) -> Void)? = nil,
        onLoadRemoteBranches: @escaping () -> Void,
        onCancelRemoteBranches: @escaping () -> Void
    ) {
        self.init(
            mode: .switchBranch,
            currentBranch: currentBranch,
            localBranches: localBranches,
            remoteBranches: remoteBranchNames,
            isLoadingRemoteBranches: isLoadingRemoteBranches,
            canSwitchBranch: canSwitchBranch,
            onPick: onSwitchBranch,
            onCreateBranch: onCreateBranch,
            onDeleteBranch: onDeleteBranch,
            onDeleteRemoteBranch: onDeleteRemoteBranch,
            onCreateMergeRequestForBranch: onCreateMergeRequestForBranch,
            branchMetadata: branchMetadata,
            defaultBranch: defaultBranch,
            onLoadBranchMetadata: onLoadBranchMetadata,
            onRequestDeleteConfirmation: onRequestDeleteConfirmation,
            onLoadRemoteBranches: onLoadRemoteBranches,
            onCancelRemoteBranches: onCancelRemoteBranches
        )
    }

    init(
        remoteBranchNames: [String]?,
        isLoadingRemoteBranches: Bool,
        selectedBranches: [String],
        pickHint: String,
        onToggleBranch: @escaping (String) -> Void,
        onLoadRemoteBranches: @escaping () -> Void,
        onCancelRemoteBranches: @escaping () -> Void
    ) {
        self.init(
            mode: .multiPick,
            currentBranch: nil,
            localBranches: [],
            remoteBranches: remoteBranchNames,
            isLoadingRemoteBranches: isLoadingRemoteBranches,
            canSwitchBranch: false,
            onPick: onToggleBranch,
            onCreateBranch: nil,
            onDeleteBranch: nil,
            onDeleteRemoteBranch: nil,
            branchMetadata: [:],
            defaultBranch: nil,
            pickHint: pickHint,
            selectedBranches: selectedBranches,
            onLoadRemoteBranches: onLoadRemoteBranches,
            onCancelRemoteBranches: onCancelRemoteBranches
        )
    }

    /// 分支对比模式便捷入口:回调上抛原值 ref 的语义见 onPick 注释。
    init(
        currentBranch: String?,
        localBranches: [String],
        remoteTrackingBranches: [String],
        pickHint: String,
        onCompare: @escaping (String) -> Void
    ) {
        self.init(
            mode: .compare,
            currentBranch: currentBranch,
            localBranches: localBranches,
            remoteBranches: remoteTrackingBranches,
            isLoadingRemoteBranches: false,
            canSwitchBranch: true,
            onPick: onCompare,
            onCreateBranch: nil,
            onDeleteBranch: nil,
            onDeleteRemoteBranch: nil,
            pickHint: pickHint,
            onLoadRemoteBranches: {},
            onCancelRemoteBranches: {}
        )
    }
}

/// orderedLocalBranches 的排序 memo:View struct 每次 body 求值都会重建,由 @State 持有跨渲染稳定。
/// 只在主线程访问、无并发,@unchecked Sendable 仅满足 @State 存储要求。
final class OrderedLocalBranchesMemo: @unchecked Sendable {
    var cachedBranches: [String]?
    var cachedMetadata: [String: GitBranchMetadata]?
    var result: [String] = []
}
