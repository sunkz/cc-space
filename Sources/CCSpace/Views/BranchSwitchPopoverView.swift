import SwiftUI

/// 分支列表弹窗:切换分支与"选择比较分支"共用同一骨架
/// (本地/远端页签 + 分支搜索 + 行列表),由 mode 驱动差异:
/// - 切换模式:本地/远端页签均提供行尾 ➕,点击后在该行下方插入输入行(原行保留),
///   以该行为基线创建新分支并切换(远端基线先 fetch 刷新 origin/ 引用);
///   远端页签需宿主联网加载,展示名带 origin/ 前缀,点击还原为裸名走 --track 回退链;
/// - 对比模式:无新建入口、无加载态,远端为本地跟踪分支(自带 origin/ 前缀),
///   点击回调收展示名;供分支比较窗口的 from/to 选择器复用。
struct BranchListPopoverView: View {
    enum Mode {
        case switchBranch
        case compare
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
    /// 点击分支:切换模式收到还原后的裸名;对比模式收到展示名。
    let onPick: (String) -> Void
    /// 新建分支:第一参为新分支名,第二参为基线(点击行尾 ➕ 所在的那条分支,
    /// 本地页签收 `.localBranch(裸名)`,远端页签收 `.remoteBranch(裸名)`)。
    let onCreateBranch: ((String, BranchBaseKind) -> Void)?
    /// 删除本地分支(切换模式本地页签提供),第二参为需连带删除的远端同名分支(裸名,nil 只删本地);
    /// 对比模式无删除入口,为 nil。
    let onDeleteBranch: ((String, String?) -> Void)?
    /// 删除远端分支(切换模式远端页签提供,收还原后的裸名);对比模式为 nil。
    let onDeleteRemoteBranch: ((String) -> Void)?
    /// 本地分支元数据(最后提交时间 / 领先落后),供行内角标与按活动排序;空字典时行内不展示元数据。
    var branchMetadata: [String: GitBranchMetadata] = [:]
    /// 仓库默认分支(裸名,如 main):远端页签该行是保护分支,不提供删除入口。
    var defaultBranch: String? = nil
    /// 对比模式行 hover/提示里的点击语义;同一骨架被"选比较分支""选要看的分支"复用,
    /// 文案跟用途走(默认"与该分支对比")。
    var comparePickHint: String = "点击与该分支对比"
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
    @State private var searchText = ""
    @State private var copiedBranch: String?
    @State private var branchDeleteCandidate: BranchDeleteCandidate?
    /// 行尾 ➕ 在该分支下方插入输入行;nil 表示没有行在展开。
    @State private var creatingFromBranch: String?
    /// orderedLocalBranches 的排序 memo(见该属性注释)。
    @State private var orderedLocalBranchesMemo = OrderedLocalBranchesMemo()

    /// 弹窗内容的统一横向留白:header、加载态、列表行共用同一常量,
    /// 左右逐像素相等、上下天然同列。
    /// 此前列表用原生 List,它给行施加左右**不相等的**系统浮动边距
    /// (实测前导 10~25pt、尾随约 9pt,随页签浮动),曾用"行上报边缘、header 跟随"
    /// 的实测方案修补,结果 header 自身左右不对称,反而更难看。
    /// 改用 ScrollView + LazyVStack 自绘列表后边距完全自控,写死常量从此可靠。
    private static let contentHorizontalInset: CGFloat = 12

    /// 切换模式专用:远端独有分支(裸名)及其展示名转换。
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

    /// 点击行为:切换模式的远端展示名要还原为裸名,其余原样上抛。
    /// remote 由调用方沿渲染路径传入(每次 body 求值只构建一次),避免逐行重建。
    private func pickPayload(
        for displayName: String,
        remote: BranchSwitchRemotePresentationState
    ) -> String {
        mode == .switchBranch && source == .remote
            ? remote.branchName(fromDisplayName: displayName)
            : displayName
    }

    /// ➕ 的基线种类:本地页签收裸名走本地 rev;远端页签把展示名(origin/x)
    /// 还原为裸名并标记为远端基线(Service 层创建前先 fetch 刷新 origin/ 引用)。
    private func createBase(
        for displayName: String,
        remote: BranchSwitchRemotePresentationState
    ) -> BranchBaseKind {
        if mode == .switchBranch, source == .remote {
            return .remoteBranch(remote.branchName(fromDisplayName: displayName))
        }
        return .localBranch(displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            listSection
        }
        // 宽度固定:弹窗尺寸不随分支名单变化,切页签/搜索/加载都不跳动,
        // 长名靠 displayText 护栏 + 行内 .head 省略 + hover 全名兜底。
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
            BranchSourceTabBar(selection: $source)

            // 远端页签手动刷新:列表经 ls-remote 实时拉取,不刷新看不到他人新推的分支。
            // 刷新进行中用转轮替代刷新按钮(位置不变),缓存展示期间它就是唯一的刷新指示。
            if mode == .switchBranch, source == .remote {
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

            // 无边框 NSSearchField 只负责输入(Esc 清空/实时回写仍是系统行为,K4):
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
            if mode == .switchBranch, newValue == .remote, remoteBranches == nil, isLoadingRemoteBranches == false {
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
    /// popover 非 key 窗口下从不显色、用户不用键盘选分支,09-25 整套移除。)
    @ViewBuilder
    private var listSection: some View {
        // 整块加载态只用于"无缓存首发":有缓存时列表照常展示,刷新指示在 header
        // 的刷新按钮位置(stale-while-revalidate,见宿主 loadRemoteBranches 注释)。
        if mode == .switchBranch, source == .remote, isLoadingRemoteBranches, remoteBranches == nil {
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
                        branchRows(state.filteredBranches, remote: remote)
                    }
                }
                .padding(.horizontal, Self.contentHorizontalInset)
            }
            .frame(height: state.listHeight)
        }
    }

    /// 两个模式各自的展示状态,输出形状一致(过滤行/空态文案/自适应高度)。
    private func listPresentationState(
        remote: BranchSwitchRemotePresentationState
    ) -> BranchPopoverListState {
        switch mode {
        case .switchBranch:
            let state = BranchSwitchListPresentationState(
                localBranches: orderedLocalBranches,
                remoteBranchNames: remote.remoteBranchNames,
                source: source,
                searchText: searchText
            )
            return BranchPopoverListState(
                filteredBranches: state.filteredBranches,
                emptyTitle: state.emptyTitle,
                emptySubtitle: state.emptySubtitle,
                listHeight: state.listHeight,
                // 刷新中不提供重试(指示已在 header 转轮),避免"重试+转轮"并排。
                showsRetry: source == .remote
                    && remote.remoteBranchNames.isEmpty
                    && isLoadingRemoteBranches == false
            )
        case .compare:
            let state = CompareBranchListPresentationState(
                branches: source == .local ? orderedLocalBranches : (remoteBranches ?? []),
                searchText: searchText
            )
            return BranchPopoverListState(
                filteredBranches: state.filteredBranches,
                emptyTitle: state.emptyTitle,
                emptySubtitle: state.emptySubtitle,
                listHeight: state.listHeight,
                showsRetry: false
            )
        }
    }

    private func branchRows(
        _ branches: [String],
        remote: BranchSwitchRemotePresentationState
    ) -> some View {
        // 当前分支的远端展示名只算一次,避免每行重复构建展示状态。
        let currentDisplayName = currentBranch.map { remote.displayName(for: $0) }
        // 行点击语义按模式区分,提示文案跟着切换;对比模式的文案由用途注入。
        let pickHint = mode == .switchBranch ? "点击切换到该分支" : comparePickHint
        // ➕ 新建入口:切换模式两个页签都给。本地页签基线即该行分支;
        // 远端页签基线为 origin/展示名对应的裸名(创建前先 fetch 刷新引用)。
        let showsCreateButton = mode == .switchBranch
        return ForEach(branches, id: \.self) { branch in
            BranchSwitchRow(
                branch: branch,
                isCurrentBranch: isRowCurrent(branch, currentDisplayName: currentDisplayName),
                copiedBranch: $copiedBranch,
                isDisabled: !canSwitchBranch,
                pickHint: pickHint,
                showsSwitchButton: mode == .switchBranch,
                showsCreateButton: showsCreateButton,
                onDelete: deleteAction(for: branch, remote: remote),
                metadata: source == .local ? branchMetadata[branch] : nil,
                showsLeadingIcon: source == .local
            ) {
                dismissPopover()
                onPick(pickPayload(for: branch, remote: remote))
            } onCreateFromHere: {
                // 同一时刻只允许一行展开;点当前展开行则收起。
                creatingFromBranch = creatingFromBranch == branch ? nil : branch
            }
            // 输入行插在该分支下方展示,原行保留(替换会把分支名整个挡掉)。
            if showsCreateButton, creatingFromBranch == branch {
                CreateBranchInlineRow(
                    baseBranch: branch,
                    isDisabled: !canSwitchBranch
                ) { name in
                    dismissPopover()
                    onCreateBranch?(name, createBase(for: branch, remote: remote))
                    creatingFromBranch = nil
                } onCancel: {
                    creatingFromBranch = nil
                }
            }
        }
    }

    /// 删除入口只在切换模式提供:本地页签删本地分支(当前分支 git 本就不能删,不给入口;
    /// 远端列表已加载且存在同名分支时可连带远端),远端页签删远端分支(收还原后的裸名,
    /// 与当前分支同名的远端分支也可删——删的是服务器引用,不影响本地检出);对比模式无删除。
    /// remote 为本次 body 求值中已构建的展示状态:ForEach 每行调用本方法,
    /// 就地重建会退化为 O(N²) 的主线程开销。
    private func deleteAction(
        for branch: String,
        remote: BranchSwitchRemotePresentationState
    ) -> (() -> Void)? {
        guard mode == .switchBranch else { return nil }
        if source == .local {
            guard onDeleteBranch != nil else { return nil }
            guard branch != currentBranch else { return nil }
            // 远端列表已加载时探测同名分支:存在则确认弹窗提供"同时删除远端"选项
            // (未加载时不预设远端状态;误删远端不存在分支由 git 侧报错反馈)。
            // 注意用原始 remoteBranches:nil 表示尚未加载,不能经 remotePresentation 折叠成空数组。
            let remoteBranch = remoteBranches?.contains(branch) == true ? branch : nil
            return { requestDeleteConfirmation(.local(branch: branch, remoteBranch: remoteBranch)) }
        }
        guard onDeleteRemoteBranch != nil else { return nil }
        // 远端行的 branch 是带 origin/ 前缀的展示名,动作用裸名、文案用展示名。
        let bareName = remote.branchName(fromDisplayName: branch)
        // 远端默认分支是保护分支,删除影响所有协作者,不提供入口。
        guard bareName != defaultBranch else { return nil }
        return { requestDeleteConfirmation(.remote(branch: bareName, displayName: branch)) }
    }

    private func requestDeleteConfirmation(_ candidate: BranchDeleteCandidate) {
        if let onRequestDeleteConfirmation {
            onRequestDeleteConfirmation(candidate)
        } else {
            branchDeleteCandidate = candidate
        }
    }

    /// 行是否指向当前所在分支:本地页签按名字;远端页签 origin/x 对应本地 x。
    private func isRowCurrent(_ branch: String, currentDisplayName: String?) -> Bool {
        if source == .local || mode == .compare {
            return branch == currentBranch
        }
        guard currentBranch != nil else { return false }
        return branch == currentDisplayName
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

/// 两个模式展示状态的统一输出形状,供共用列表渲染。
struct BranchPopoverListState {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String
    let listHeight: CGFloat
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

    /// 弹窗固定宽度:不随分支名单变化,避免切页签/搜索/加载时面板跳动。
    static let fixedPopoverWidth: CGFloat = 340

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

/// 单条分支行:当前分支打勾、点击切换(分支名悬停有提示)、
/// 右侧提供切换/复制分支名/删除/新建入口。供切换分支/分支比较选择器两个模式复用。
struct BranchSwitchRow: View {
    let branch: String
    let isCurrentBranch: Bool
    @Binding var copiedBranch: String?
    let isDisabled: Bool
    /// 非当前分支行分支名的悬停提示,按模式区分点击语义(切换/对比)。
    var pickHint: String? = nil
    /// true(切换模式)时非当前分支行提供显式"切换到此分支"按钮;整行点击是隐式入口,行高小容易误触。
    var showsSwitchButton: Bool = false
    /// true(切换模式本地页签)时行尾提供 ➕,点击后在该行下方插入输入行。
    var showsCreateButton: Bool = false
    /// 删除入口回调;nil(对比模式或不可删的行,如本地当前分支)时按钮隐藏。
    var onDelete: (() -> Void)? = nil
    /// 该分支的元数据(最后提交时间 / 领先落后);nil(远端页签/元数据未加载)时不展示角标。
    var metadata: GitBranchMetadata? = nil
    /// true(本地页签):行首预留 10pt 指示列,当前分支行画小对勾、其他行留白对齐;
    /// false(远端页签):不显示对勾也不预留(当前分支标识只属于本地页签)。
    var showsLeadingIcon: Bool = true
    let onSwitch: () -> Void
    /// 行尾 ➕ 点击:宿主把该行切换为输入框。
    var onCreateFromHere: (() -> Void)? = nil
    @State private var resetTask: Task<Void, Never>?
    @State private var isDeleteHovering = false

    /// 分支名可能被护栏截断/头部省略,hover 提示始终给全名。
    private var nameHelp: String {
        if isCurrentBranch { return "当前分支：\(branch)" }
        guard let pickHint else { return branch }
        return "\(branch)\n\(pickHint)"
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

    /// 当前分支的行首小对勾。
    private var currentBranchCheck: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsLeadingIcon {
                // 本地页签:整列预留,勾/空白同宽,分支名跨行对齐;远端页签不显示对勾。
                Group {
                    if isCurrentBranch {
                        currentBranchCheck
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
            }
            Text(BranchNameDisplay.displayText(for: branch))
                .lineLimit(1)
                // 分支名区分度在尾部:宽度不足时从头部省略,而不是切掉尾部。
                .truncationMode(.head)
                .ccspaceQuickHelp(nameHelp)
            Spacer(minLength: 6)
            metadataView
            // 行内操作簇:图标统一 20×20 定尺、间距 2,悬停高亮块跨行对齐。
            HStack(spacing: 2) {
                // 显式切换入口,行内动作之首(紧靠元数据);当前分支与禁用态(如正在同步)不提供。
                if showsSwitchButton, isCurrentBranch == false, isDisabled == false {
                    Button(action: onSwitch) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .ccspaceQuickHelp("切换到此分支", providesLabel: true)
                    .accessibilityLabel("切换到此分支")
                }
                // 复制分支名到剪贴板。
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
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .ccspaceQuickHelp("复制分支名", providesLabel: true)
                // 删除分支(可用性由宿主 deleteAction 决定,当前本地分支收不到回调);
                // 悬停转红提示破坏性。
                if onDelete != nil {
                    Button(action: { onDelete?() }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
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
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
                    .ccspaceQuickHelp("基于该分支创建新分支并切换", providesLabel: true)
                    .accessibilityLabel("基于该分支创建新分支")
                }
            }
        }
        // 前导保留 4pt 内收;尾随 -2 为视觉微调:➕ 图标在 20×20 按钮框内居中,
        // 字形右缘比框缘缩进约 4~5pt,trailing 0 后仍比胶囊右缘(容器 12 + 胶囊内收 4)
        // 略偏左,再右移 2pt 让字形右缘压在胶囊右缘那条竖线上。
        // (自绘 LazyVStack 无 List 裁切,小幅负 padding 安全;还差就动这个值。)
        .padding(.leading, 4)
        .padding(.trailing, -2)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isDisabled == false, isCurrentBranch == false else { return }
            onSwitch()
        }
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
                // 与分支行 10pt 指示列对齐(输入行左侧固定显示绿色 ➕);
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

/// K4 玻璃皮肤底座:半透明材质 + 内侧白色高光描边。
/// 弹窗内没有系统玻璃容器,自绘不会重现设置页标题栏的"双层背景"问题。
private func branchHeaderGlassCorner(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
        )
}

/// 来源页签(本地/远端),K4 玻璃质感:材质底座 + 系统侧栏选中色滑块。
/// 不用 NSSegmentedControl——它的 bezel 画不出这套皮肤;滑动动画沿用
/// 设置页定案的弹簧参数(response 0.34 / damping 0.74)。
struct BranchSourceTabBar: View {
    @Binding var selection: BranchSwitchListSource
    @Namespace private var sliderNamespace

    var body: some View {
        HStack(spacing: 2) {
            tabButton("本地", for: .local)
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

/// 原生搜索输入组件(K4 玻璃皮肤版):无边框 NSSearchField 只负责输入行为——
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
    /// 切换分支模式:远端独有分支需宿主联网加载,两个页签均支持行尾 ➕
    /// 基于该行分支(本地或远端)新建、删除本地/远端分支。
    /// `onCreateBranch` 第二参为基线种类(远端行已还原为裸名)。
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
            branchMetadata: branchMetadata,
            defaultBranch: defaultBranch,
            onLoadBranchMetadata: onLoadBranchMetadata,
            onRequestDeleteConfirmation: onRequestDeleteConfirmation,
            onLoadRemoteBranches: onLoadRemoteBranches,
            onCancelRemoteBranches: onCancelRemoteBranches
        )
    }

    /// 分支对比模式:远端为本地跟踪分支(带 origin/ 前缀),点击回调收展示名;
    /// 供分支比较窗口的 from/to 选择器与提交记录窗口的分支切换器复用,
    /// `pickHint` 按用途定制行 hover 提示(默认"点击与该分支对比")。
    init(
        currentBranch: String?,
        localBranches: [String],
        remoteTrackingBranches: [String],
        pickHint: String = "点击与该分支对比",
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
            comparePickHint: pickHint,
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
