import SwiftUI

/// 分支列表弹窗:切换分支、"选择比较分支"与"多选 MR 目标分支"共用同一骨架
/// (本地/远端页签 + 分支搜索 + 行列表),由 mode 驱动差异:
/// - 三个模式的列表一律**展示裸分支名**(不带 origin/ 前缀;仅对比模式在同批行里
///   裸名撞车时保留前缀),本地还是远端靠页签区分;
/// - 切换模式:本地/远端页签均提供行尾 ➕,点击后在该行下方插入输入行(原行保留),
///   以该行为基线创建新分支并切换(远端基线先 fetch 刷新 origin/ 引用);
///   远端页签需宿主联网加载,点击上抛裸名走 --track 回退链;
/// - 对比模式:无新建入口、无加载态,宿主喂进来的是本地跟踪引用(origin/x),
///   行内只显示裸名、点击回调仍上抛引用名(拿到就能直接给 git 用);
/// - 多选模式(MR 目标分支配置):只有远端页签(设置页的仓库未必有本地检出,
///   本地名单无从谈起),行只表示"已选/未选",点选即时上抛且**面板不关**,
///   便于一次配完多条;无切换/新建/删除/MR 入口。
struct BranchListPopoverView: View {
    enum Mode {
        case switchBranch
        case compare
        case multiPick
    }

    /// 弹窗同步直关入口(由 ccspacePopover 注入):pick/新建类回调先直关面板
    /// 再上抛宿主。不依赖 binding 回写链路——那条链路跨窗口、要等下一轮
    /// SwiftUI 事务,与派发动作的状态写入同帧竞争,面板会间歇性关不掉。
    @Environment(\.ccspacePopoverDismiss) private var dismissPopover

    let mode: Mode
    let currentBranch: String?
    let localBranches: [String]
    /// 切换模式:远端裸分支名(nil 表示尚未加载);对比模式:本地跟踪分支(带前缀)。
    let remoteBranches: [String]?
    let isLoadingRemoteBranches: Bool
    let canSwitchBranch: Bool
    /// 点击分支:切换/多选模式收到远端裸名;**对比模式收到可直接交给 git 的跟踪引用
    /// (`origin/x`)**——它的值就是 ref,只在展示层去前缀,别顺手改成上抛裸名。
    let onPick: (String) -> Void
    /// 新建分支:第一参为新分支名,第二参为基线(点击行尾 ➕ 所在的那条分支,
    /// 本地页签收 `.localBranch(裸名)`,远端页签收 `.remoteBranch(裸名)`)。
    let onCreateBranch: ((String, BranchBaseKind) -> Void)?
    /// 删除本地分支(切换模式本地页签提供),第二参为需连带删除的远端同名分支(裸名,nil 只删本地);
    /// 对比模式无删除入口,为 nil。
    let onDeleteBranch: ((String, String?) -> Void)?
    /// 删除远端分支(切换模式远端页签提供,收还原后的裸名);对比模式为 nil。
    let onDeleteRemoteBranch: ((String) -> Void)?
    /// 以当前分支为源、向指定分支创建 MR(切换模式各行提供,收还原后的裸名目标分支);
    /// nil(对比模式/无宿主入口)时行内不提供按钮。
    var onCreateMergeRequestForBranch: ((String) -> Void)? = nil
    /// 本地分支元数据(最后提交时间 / 领先落后),供行内角标与按活动排序;空字典时行内不展示元数据。
    var branchMetadata: [String: GitBranchMetadata] = [:]
    /// 仓库默认分支(裸名,如 main):远端页签该行是保护分支,不提供删除入口。
    var defaultBranch: String? = nil
    /// 非切换模式的行点击提示:同一骨架被"选比较分支""选要看的分支""配 MR 目标分支"
    /// 复用,文案跟用途走,由各自的便捷 init 注入。
    var pickHint: String = ""
    /// 多选模式:当前已配置的分支(裸名)。行据此打勾,点选在宿主侧增删。
    var selectedBranches: [String] = []
    /// 弹窗出现时加载分支元数据(与 onLoadRemoteBranches 同一时机)。
    var onLoadBranchMetadata: (() -> Void)? = nil
    /// 删除确认上抛给宿主承载。
    ///
    /// popover 是 transient behavior,内嵌 alert 会因弹出时的焦点切换被连带关闭,
    /// 甚至出现"点了取消但删除仍被执行"的窗口期——删除分支不可恢复,确认必须由
    /// 宿主(行/窗口)弹。为 nil 时退回弹窗内部的 alert(兼容无宿主的调用点)。
    var onRequestDeleteConfirmation: ((BranchDeleteCandidate) -> Void)? = nil
    let onLoadRemoteBranches: () -> Void
    let onCancelRemoteBranches: () -> Void

    @State private var source: BranchSwitchListSource = .local
    /// 当前生效的页签:多选模式只有远端,而 `source` 的初值改不动(成员式 init 由
    /// SwiftUI 生成,初值统一是 `.local`),onAppear 改写又晚于首帧渲染——
    /// 首帧会拿空本地名单渲染出"暂无可切换的本地分支"。所有读取走这里,屏蔽那一帧。
    private var effectiveSource: BranchSwitchListSource {
        mode == .multiPick ? .remote : source
    }
    @State private var searchText = ""
    @State private var copiedBranch: String?
    @State private var branchDeleteCandidate: BranchDeleteCandidate?
    /// 行尾 ➕ 在该分支下方插入输入行;nil 表示没有行在展开。
    @State private var creatingFromBranch: String?
    /// orderedLocalBranches 的排序 memo(见该属性注释)。
    @State private var orderedLocalBranchesMemo = OrderedLocalBranchesMemo()

    /// 弹窗内容的统一横向留白:header、加载态、列表行共用同一常量,左右逐像素相等。
    /// 不用原生 List 是因为它给行施加左右**不相等的**系统浮动边距(实测前导 10~25pt),
    /// header 与行永远对不齐;自绘列表边距完全自控。
    private static let contentHorizontalInset: CGFloat = 12

    /// 远端名单要不要联网拉:切换与多选模式的远端页签都来自 `ls-remote`
    /// (对比模式的"远端"是本地跟踪分支,本就在仓库里,无需加载与刷新)。
    private var loadsRemoteFromNetwork: Bool { mode != .compare }

    /// 切换/多选模式专用:远端独有分支(裸名)。
    private var remotePresentation: BranchSwitchRemotePresentationState {
        BranchSwitchRemotePresentationState(remoteBranches: remoteBranches)
    }

    /// 本地页签展示顺序:按最近活动排序(元数据未到达时保持字母序原样)。
    /// memo 化:搜索过滤的每次按键都触发 body 重算,全量排序(逐分支查角标)
    /// 在大仓库时是可观的主线程开销——与 Support 层"重排序在加载时做一次"的原则对齐,
    /// 输入(branchMetadata/localBranches)不变则复用上次结果。
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
            // header 与列表之间不画分隔线:菜单式干净列表,行本身也无分隔线。
            listSection
        }
        // 宽度固定:弹窗尺寸不随分支名单变化,切页签/搜索/加载都不跳动,
        // 长名靠 displayText 护栏截"前缀/…尾部" + 行内 .head 省略 + hover 全名兜底。
        .frame(width: BranchNameDisplay.fixedPopoverWidth)
        // 回退路径(无宿主承载确认)复用行视图同一套 BranchDeleteConfirmationModifier:
        // 此前这里是逐行复制的第二套 alert 实现,两处行为被迫人肉同步维护。
        .modifier(
            BranchDeleteConfirmationModifier(
                candidate: $branchDeleteCandidate,
                onDeleteBranch: { branch, remoteBranch in
                    onDeleteBranch?(branch, remoteBranch)
                },
                onDeleteRemoteBranch: { branch in
                    onDeleteRemoteBranch?(branch)
                }
            )
        )
        .onAppear {
            onLoadBranchMetadata?()
            onLoadRemoteBranches()
        }
        .onDisappear {
            onCancelRemoteBranches()
        }
    }

    private var header: some View {
        // 间距收紧:页签/刷新/搜索框贴排,避免页签与刷新之间出现明显空档。
        HStack(spacing: 4) {
            // 三个模式都画页签条;多选模式只留"远端"一段(它没有本地名单)。
            BranchSourceTabBar(
                selection: Binding(get: { effectiveSource }, set: { source = $0 }),
                showsLocalTab: mode != .multiPick
            )

            // 远端页签手动刷新:列表经 ls-remote 实时拉取,不刷新看不到他人新推的分支。
            // 刷新进行中用转轮替代刷新按钮(位置不变),缓存展示期间它就是唯一的刷新指示。
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

            // 无边框 NSSearchField 只负责输入(Esc 清空/实时回写仍是系统行为):
            // 它的放大镜图标不占文本位、会和占位符重叠,放大镜与清空按钮改自绘垫在玻璃胶囊里。
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
            // 吃掉页签之外的全部剩余宽度:胶囊右缘 = 容器留白 12 + 胶囊内收 4 = 距右 16pt,
            // 与行尾 ➕ 的右缘(容器留白 12 + 行内收 4)落在同一条竖线。
            // (不撑满的话,胶囊右缘由 NSSearchField 内在宽度决定,trailing padding 加不加都不动它。)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(branchHeaderGlassCorner(radius: 7))
        }
        .frame(maxWidth: .infinity)
        // 与列表行同一常量留白:左右相等、上下同列,不依赖任何实测值。
        .padding(.horizontal, Self.contentHorizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onChange(of: source) { _, newValue in
            // onAppear 只在首次出现时触发;切回远端页签时若仍未加载则补一次。
            if loadsRemoteFromNetwork, newValue == .remote, remoteBranches == nil, isLoadingRemoteBranches == false {
                onLoadRemoteBranches()
            }
        }
    }

    /// 列表区:切换模式的远端页签有联网加载态;其余情况按展示状态渲染行与空态。
    /// 远端展示状态在每次 body 求值中只构建一次,再沿行渲染传下去——
    /// 否则 ForEach 每行各建一份(含排序),分支多时是 O(N²) 的主线程开销。
    /// 列表用 ScrollView + LazyVStack 而非原生 List:List 给行施加左右**不相等的**
    /// 系统浮动边距,是 header 与行对齐问题反复复发的根因;自绘列表后留白完全由
    /// contentHorizontalInset 决定。(曾有 ↑↓/回车键盘导航+选中高亮,实测高亮在
    /// popover 非 key 窗口下从不显色、用户不用键盘选分支,整套移除。
    @ViewBuilder
    private var listSection: some View {
        // 整块加载态只用于"无缓存首发":有缓存时列表照常展示,刷新指示在 header
        // 的刷新按钮位置(stale-while-revalidate,见宿主 loadRemoteBranches 注释)。
        if loadsRemoteFromNetwork, effectiveSource == .remote, isLoadingRemoteBranches, remoteBranches == nil {
            // 加载态也用固定高度:与加载完成后的列表同高,不产生跳动。
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
                // 必须 LazyVStack:VStack 会在主线程全量实例化所有行,实测首次布局
                // 50 分支 163ms、500 分支 1.0s、2000 分支 5.3s——列表一从远端加载回来
                // 整个 app 卡死数秒(滚动区只展示 5 行,其余行纯属白付的布局成本)。
                LazyVStack(alignment: .leading, spacing: 0) {
                    if state.filteredBranches.isEmpty {
                        listEmptyView(state)
                    } else {
                        branchRows(state.filteredBranches)
                    }
                }
                .padding(.horizontal, Self.contentHorizontalInset)
            }
            // 高度固定,与分支数/页签/搜索词无关:面板尺寸恒定不跳动。
            .frame(height: BranchSwitchListPresentationState.fixedListHeight)
        }
    }

    /// 各模式共用的展示状态,输出形状一致(过滤行/空态文案/是否给重试)。
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
                // 刷新中不提供重试(指示已在 header 转轮),避免"重试+转轮"并排。
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
        // 多选面板:已添加的目标分支置顶,其余保持原序(稳定排序,点选只让被操作
        // 那一行在两组之间移动,不会整表乱跳)。
        let rows = mode == .multiPick
            ? BranchSelectionOrder.selectedFirst(branches, selected: selectedBranches)
            : branches
        // 行点击语义按模式区分,提示文案跟着切换;对比模式的文案由用途注入。
        let rowPickHint = mode == .switchBranch ? "点击切换到该分支" : pickHint
        // ➕ 新建入口:切换模式两个页签都给(基线都是该行裸分支名,远端基线创建前先 fetch 刷新引用)。
        let showsCreateButton = mode == .switchBranch
        // "向该分支创建 MR"入口:仅切换模式且宿主提供回调时给;对比模式与无宿主的
        // 调用点(如提交记录窗口的分支切换器)不提供。
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
                // 对比模式的"远端"页签喂进来的是跟踪引用(origin/main 这类),
                // 面板统一只展示裸名;复制与回调仍用真值,拿到就能直接给 git 用。
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
                // 多选模式:行只区分"已添加/未添加",空位也占住同一格,保证各行
                // 分支名的右缘一致。
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
                // 同一时刻只允许一行展开;点当前展开行则收起。
                creatingFromBranch = creatingFromBranch == branch ? nil : branch
            } onCreateMergeRequestForBranch: {
                // 上抛的是目标分支裸名,与切换动作同一口径。
                dismissPopover()
                onCreateMergeRequestForBranch?(branch)
            }
            // 输入行插在该分支下方展示,原行保留(替换会把分支名整个挡掉)。
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

    /// 删除入口只在切换模式提供:本地页签删本地分支(当前分支 git 本就不能删,不给入口;
    /// 远端列表已加载且存在同名分支时可连带远端),远端页签删远端分支(收裸名,
    /// 与当前分支同名的远端分支也可删——删的是服务器引用,不影响本地检出);对比模式无删除。
    private func deleteAction(for branch: String) -> (() -> Void)? {
        guard mode == .switchBranch else { return nil }
        if effectiveSource == .local {
            guard onDeleteBranch != nil else { return nil }
            guard branch != currentBranch else { return nil }
            // 远端列表已加载时探测同名分支:存在则确认弹窗提供"同时删除远端"选项
            // (未加载时不预设远端状态;误删远端不存在分支由 git 侧报错反馈)。
            // 注意用原始 remoteBranches:nil 表示尚未加载,不能经 remotePresentation 折叠成空数组。
            let remoteBranch = remoteBranches?.contains(branch) == true ? branch : nil
            return { requestDeleteConfirmation(.local(branch: branch, remoteBranch: remoteBranch)) }
        }
        guard onDeleteRemoteBranch != nil else { return nil }
        // 远端默认分支是保护分支,删除影响所有协作者,不提供入口。
        guard branch != defaultBranch else { return nil }
        // 列表里展示裸名,但删除是破坏性动作:确认文案仍写全 origin/<分支> 说清删的是远端引用。
        return { requestDeleteConfirmation(.remote(branch: branch, displayName: "origin/\(branch)")) }
    }

    private func requestDeleteConfirmation(_ candidate: BranchDeleteCandidate) {
        if let onRequestDeleteConfirmation {
            onRequestDeleteConfirmation(candidate)
        } else {
            branchDeleteCandidate = candidate
        }
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

/// 各模式展示状态的统一输出形状,供共用列表渲染。
struct BranchPopoverListState {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String
    let showsRetry: Bool
}

/// 待确认的删除目标:均记裸分支名(动作用);远端分支展示名带 origin/ 前缀由文案现算。
/// 本地分支若已探测到远端同名分支,确认弹窗提供"仅本地/同时删除"两个选项;
/// 远端删除会推送删除引用到服务器,确认文案单独强调影响协作者。
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

/// 长分支名的展示策略。分支名的区分度集中在尾部(feature/xxx-kezheng 的语义在 xxx-kezheng),
/// 尾部截断恰好切掉关键信息,因此弹窗宽高固定(见 fixedPopoverWidth 与固定列表高度),
/// 长名靠两层兜底:
/// - 极端超长名由 displayText 护栏截成"前缀/…尾部";
/// - 仍放不下时行内用 truncationMode(.head) 从头部省略,优先保住尾部,hover 提示给全名。
enum BranchNameDisplay {
    /// 超长名护栏阈值:超过该字符数才做"前缀/…尾部"预截断。
    static let maxDisplayCharacters = 60

    /// 弹窗固定宽度:不随分支名单变化,切页签/搜索/加载都不跳动。
    /// **所有分支面板共用这一个常量**(切换 / 对比选择器 / MR 目标分支多选 / 远端加载态),
    /// 统一 300pt:长名靠 .head 省略 + hover 全名兜底。
    static let fixedPopoverWidth: CGFloat = 300

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

/// 单条分支行:当前分支以「accent 蓝 + 半粗分支名 + 行尾对勾」标识,不给任何底色
/// (常驻底色与这层的 hover 灰同档,会被读成"鼠标停着的那行")、
/// 点击切换(分支名悬停有提示),右侧提供切换/创建 MR/复制分支名/删除/新建入口;
/// 可点击行 hover 出菜单式灰底,当前行/禁用行不给。
/// 供切换分支 / 分支比较选择器 / MR 目标分支多选三种模式复用。
struct BranchSwitchRow: View {
    let branch: String
    /// 行内展示用的分支名:与 `branch` 不同时(对比模式远端页签的跟踪引用 origin/x),
    /// 标签与 hover 只给裸名,复制/回调/删除仍用 `branch` 真值。
    var displayBranch: String? = nil
    let isCurrentBranch: Bool
    @Binding var copiedBranch: String?
    let isDisabled: Bool
    /// 非当前分支行分支名的悬停提示,按模式区分点击语义(切换/对比)。
    var pickHint: String? = nil
    /// true(切换模式)时非当前分支行提供显式"切换到此分支"按钮;整行点击是隐式入口,行高小容易误触。
    var showsSwitchButton: Bool = false
    /// true(切换模式本地页签)时行尾提供 ➕,点击后在该行下方插入输入行。
    var showsCreateButton: Bool = false
    /// true(切换模式且宿主提供回调)时行内提供"向该分支创建 MR"按钮;
    /// 当前分支行不显示——源分支与目标分支不能相同。
    var showsMergeRequestButton: Bool = false
    /// 多选模式(MR 目标分支):该行已是被选项,动作簇首位显示 accent 对勾、分支名跟着加重。
    var selected: Bool = false
    /// 多选模式下未选中的行也要占住对勾那一格,否则各行分支名的右缘会差出一格宽度。
    var showsSelectionSlot: Bool = false
    /// 复制分支名按钮:多选面板(配 MR 目标分支)用不上,故去掉
    /// (面板宽度已全 app 统一为一个常量,不再按场景收窄)。
    var showsCopyButton: Bool = true
    /// 删除入口回调;nil(对比模式或不可删的行,如本地当前分支)时按钮隐藏。
    var onDelete: (() -> Void)? = nil
    /// 该分支的元数据(最后提交时间 / 领先落后);nil(远端页签/元数据未加载)时不展示角标。
    var metadata: GitBranchMetadata? = nil
    let onSwitch: () -> Void
    /// 行尾 ➕ 点击:宿主把该行切换为输入框。
    var onCreateFromHere: (() -> Void)? = nil
    /// "向该分支创建 MR"点击:宿主以当前分支为源、本行为目标生成 MR 链接并打开浏览器。
    var onCreateMergeRequestForBranch: (() -> Void)? = nil
    @State private var resetTask: Task<Void, Never>?
    @State private var isDeleteHovering = false
    @State private var isRowHovering = false

    /// 行 hover 菜单式灰底:仅"整行点击有效"的行显示。当前分支行不占常驻底色——它与 hover
    /// 同色阶会被读成"鼠标停着的那行",标识改由行尾的 accent 对勾承担。
    private var rowHoverBackground: Color {
        guard isDisabled == false, isCurrentBranch == false, isRowHovering else { return .clear }
        return Color.primary.opacity(0.06)
    }

    /// 行内可见的分支名(默认与真值一致;对比模式远端页签去掉 origin/ 前缀)。
    private var label: String { displayBranch ?? branch }

    /// 分支名可能被护栏截断/头部省略,hover 提示始终给全名。
    private var nameHelp: String {
        if isCurrentBranch { return "当前分支：\(label)" }
        guard let pickHint else { return label }
        return "\(label)\n\(pickHint)"
    }

    /// 整行命中区的动作:鼠标点击与读屏默认动作共用同一条守卫,不让两个入口漂移。
    private func handleRowTap() {
        guard isDisabled == false, isCurrentBranch == false else { return }
        onSwitch()
    }

    /// 行内元数据角标:上游已删除警示 / ⇡领先 / ⇣落后 / 最后提交相对时间,
    /// 次要样式避免抢分支名的焦点;完整含义在行 hover 提示(metadataHelp)里给出。
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
                // 分支名区分度在尾部:宽度不足时从头部省略,而不是切掉尾部。
                .truncationMode(.head)
                // 当前分支标识:accent 蓝半粗字 + 行尾对勾(见下方动作簇),行内不给底色。
                // 多选模式的"已选"行复用同一套标识(语义都是"这条已经在了")。
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
            // 行内操作簇:图标统一 20×20 定尺、间距 2,悬停高亮块跨行对齐。
            // 动作图标一律 label 墨色:.secondary 灰在切换按钮的 accent 蓝对比下
            // 会被读成"状态点缀"而非可点按钮。悬停浅底由 .borderless 提供。
            HStack(spacing: 2) {
                // 动作簇首位:显式切换入口(紧靠元数据)。当前分支与多选"已添加"都把这格
                // 换成不可点的对勾——同一样式同一位置,动作簇因此与邻行同列对齐。
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
                    // 未选中的多选行也占住这一格,否则各行分支名的右缘对不齐(对勾列)。
                    Color.clear.frame(width: 20, height: 20)
                }
                // 向该分支创建 MR(当前分支 → 该行分支,直接打开网页、不含 Push);
                // 仓库唯一的 MR 入口。当前分支行不显示:源与目标同分支无法建 MR。
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
                // 复制分支名到剪贴板。
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
                // 删除分支(可用性由宿主 deleteAction 决定,当前本地分支收不到回调);
                // 悬停转红提示破坏性。
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
                // 基于该分支新建(行尾 ➕,切换模式本地/远端页签均提供);当前分支行同样提供。
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
        // 前导保留 4pt 内收;尾随 0:行尾 ➕ 的 20×20 按钮框右缘落在容器右缘。
        .padding(.leading, 4)
        .padding(.vertical, 6)
        // hover 灰底垫在整行命中区。圆角 7pt 取自左栏选中 chip 像素采样(README 截图 2x 约 14px)。
        // 尾随只收 2pt(左右缘≈4/2,视觉对称):此前收 6pt 而 ➕ 框右缘又外扩 2pt,
        // 灰底从加号中间穿过、没把按钮包住。
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowHoverBackground)
                .padding(.trailing, 2)
        }
        .contentShape(Rectangle())
        // 悬浮提示挂在整行而非分支名上:名字右侧的空白处也该能弹出全名/点击语义,
        // 否则鼠标得"瞄准"文字才出提示。划到行内按钮时由按钮自己的提示接管
        // (气泡协调器保证同一时刻只有一个)。
        .ccspaceQuickHelp(nameHelp)
        .onTapGesture(perform: handleRowTap)
        // 多选面板(MR 目标分支)的整行是唯一命中区,行内一个按钮都没有:只给
        // onTapGesture 的话,键盘与读屏都够不着这条唯一的配置入口。
        .modifier(BranchRowPickAction(enabled: showsSelectionSlot, action: handleRowTap))
        .onHover { isRowHovering = $0 }
        .opacity(isDisabled ? 0.5 : 1)
        .onDisappear {
            // 弹窗关闭后不再持有复位任务:它会写父视图的 copiedBranch。
            // 先清掉本行的 copiedBranch 再取消:行因过滤/滚动消失而弹窗仍开着时,
            // 只取消不复位会让父级状态悬留,行重新可见后对勾常亮到弹窗关闭。
            if copiedBranch == branch {
                copiedBranch = nil
            }
            resetTask?.cancel()
            resetTask = nil
        }
    }
}

/// 多选行的读屏/键盘动作:把整行合成一个带按钮语义的元素并挂上默认动作。
///
/// 只在多选模式启用:那种行里没有任何按钮,合并不会遮蔽谁;切换/对比模式的行内有
/// 复制、删除、建 MR 等按钮,一旦合并反而会把它们从读屏树里抹掉,因此保持原样。
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

/// "基于该分支新建"的输入行:点击行尾 ➕ 后插在该分支行下方,
/// 回车或"创建"以该行分支为基线创建新分支并切换;✕ 收起移除本行。
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
                // 行首绿色 ➕ 是"新建输入行"自身的动作标识;
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
            // 非法分支名(空格/`^`/`..` 等)在输入侧就拦下,与新建工作区表单同一条校验规则,
            // 而不是把裸 git 报错甩给用户。
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

/// 玻璃底座:半透明材质 + 内侧白色高光描边。
/// 弹窗内没有系统玻璃容器,自绘不会重现设置页标题栏的"双层背景"问题。
private func branchHeaderGlassCorner(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
        )
}

/// 来源页签(本地/远端):玻璃材质底座 + 系统侧栏选中色滑块。
/// 不用 NSSegmentedControl——它的 bezel 画不出这套皮肤;滑动动画沿用
/// 设置页定案的弹簧参数(response 0.34 / damping 0.74)。
struct BranchSourceTabBar: View {
    @Binding var selection: BranchSwitchListSource
    /// 多选面板只有远端名单(设置页的仓库未必有本地检出),此时只画"远端"一段,
    /// 位置与两页签时一致,header 仍是「远端 · 刷新 · 搜索」。
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
                // 浅色模式"蓝底黑字"的根因是**文字色**取错:selectedControlTextColor
                // 的配套底色是浅灰(浅色模式=黑字),配强调蓝底就成了黑字压蓝底。
                // 底色 selectedContentBackgroundColor(强调蓝、随高亮色)不变,文字钉成白色。
                // (transient popover 存续期即 key 窗口,失焦退灰的场景看不到,白字安全。)
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

/// 原生搜索输入组件:无边框 NSSearchField 只负责输入行为——
/// controlTextDidChange 实时回写绑定、Esc 清空(cancelOperation 手动派发 action 同步)。
/// 放大镜与清空按钮因 cell 图标不占文本位(会与占位符重叠)改由 SwiftUI 侧自绘。
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
        // 放大镜不占文本位会与占位符重叠、清空按钮布局不可控:
        // 摘掉 cell 的搜索/清空按钮子件,放大镜与清空由 SwiftUI 侧自绘。
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
    /// 切换分支模式的便捷入口;模式差异见类型头注释。
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

    /// MR 目标分支多选模式的便捷入口;模式差异见类型头注释。
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

    /// 分支对比模式的便捷入口:宿主喂进来的是本地跟踪引用,**点击回调上抛原值 ref**
    /// (列表只展示裸名,值仍要能直接给 git 用);`pickHint` 按用途定制行 hover 提示。
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

/// orderedLocalBranches 的排序 memo。View struct 每次 body 求值都会重建,
/// memo 由 @State 持有跨渲染稳定(与 DiffViewerView 的 PatchParseMemo 同模式)。
/// 只在主线程访问,无并发,故无需锁,标 @unchecked Sendable 仅满足 @State 存储要求。
final class OrderedLocalBranchesMemo: @unchecked Sendable {
    var cachedBranches: [String]?
    var cachedMetadata: [String: GitBranchMetadata]?
    var result: [String] = []
}
