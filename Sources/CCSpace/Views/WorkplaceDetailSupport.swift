import AppKit
import Foundation

struct RepositoryBranchCacheKey: Hashable {
    let workplaceID: UUID
    let repositoryID: UUID

    init(workplaceID: UUID, repositoryID: UUID) {
        self.workplaceID = workplaceID
        self.repositoryID = repositoryID
    }

    init(state: RepositorySyncState) {
        self.init(
            workplaceID: state.workplaceID,
            repositoryID: state.repositoryID
        )
    }
}

struct RepositoryBranchSnapshot: Equatable {
    let currentBranch: String?
    let branches: [String]
    let status: GitBranchStatusSnapshot?
}

enum WorkplaceBranchLoader {
    static let maxConcurrentSnapshotLoads = 8

    static func loadBranchSnapshots(
        for syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> [RepositoryBranchCacheKey: RepositoryBranchSnapshot] {
        let branchStates = syncStates.filter(\.hasLocalDirectory)
        guard branchStates.isEmpty == false else { return [:] }

        let results = await ConcurrencyUtilities.runLimitedTasks(
            branchStates,
            maxConcurrentTasks: maxConcurrentSnapshotLoads
        ) { state in
            await loadBranchSnapshot(for: state, gitService: gitService)
        }

        var snapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
        for (key, snapshot) in results {
            if let snapshot {
                snapshots[key] = snapshot
            }
        }
        return snapshots
    }

    private static func loadBranchSnapshot(
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> (RepositoryBranchCacheKey, RepositoryBranchSnapshot?) {
        let key = RepositoryBranchCacheKey(state: state)

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        // 只取主快照。此前这里并行多取一次远端跟踪分支填到
        // RepositoryBranchSnapshot.remoteBranches,而该字段全仓没有任何读取点——
        // 等于每次刷新(每仓库)白跑一个 git 进程。
        let info = await gitService.branchSnapshotInfo(in: state.localPath)
        guard let info else {
            return (key, nil)
        }

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        return (
            key,
            RepositoryBranchSnapshot(
                currentBranch: info.currentBranch,
                branches: normalizedBranches(
                    info.branches,
                    currentBranch: info.currentBranch
                ),
                status: info.status
            )
        )
    }
}

/// 分支名单归一:去空白、去重、按本地化标准顺序排序。
/// 排序用的是 localizedStandardCompare,上千分支代价可观——必须在加载时
/// (后台线程)做一次,弹窗展示状态只消费结果,不做重排序。
enum BranchListNormalization {
    static func remoteBranches(_ branches: [String]) -> [String] {
        Array(
            Set(
                branches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// 分支按"最近活动"排序:最后提交时间新的在前。
/// 元数据未加载/无时间的分支保持原顺序(字母序)排在最后——
/// 弹窗首帧(元数据未到)与字母序一致,数据到达后才换序,不会闪跳。
enum BranchActivityOrder {
    static func sorted(
        _ branches: [String],
        metadata: [String: GitBranchMetadata]
    ) -> [String] {
        branches.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = metadata[lhs.element]?.lastCommitDate
                let rhsDate = metadata[rhs.element]?.lastCommitDate
                switch (lhsDate, rhsDate) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                // 同时间/都无时间:保持输入顺序(名单已按字母序归一)。
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

private func normalizedBranches(
    _ branches: [String],
    currentBranch: String?
) -> [String] {
    var normalized = branches
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if let currentBranch,
       normalized.contains(currentBranch) == false {
        normalized.append(currentBranch)
    }

    return Array(Set(normalized)).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }
}

enum WorkplaceSystemActions {
    static func openTerminal(_ terminal: ExternalEditor, at path: String) throws {
        // 与 openInEditor 同一口径:归一化 + 存在性校验,否则空串/失效路径会让 Terminal
        // 静默打开默认目录,用户以为打开了工作区。
        let normalizedPath = LocalPathSafety.normalizedPath(path)
        guard normalizedPath.isEmpty == false,
              FileManager.default.fileExists(atPath: normalizedPath) else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "目录不存在，无法打开终端"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", terminal.applicationURL.path, normalizedPath]
        // /usr/bin/open 的告警/错误不面向用户:不接管就会继承父进程 fd(打包成 app 时
        // 指向不可写位置),口径与 openInEditor 一致。
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }

    static func showInFinder(at path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func openInBrowser(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法打开浏览器"]
            )
        }
    }
}

struct WorkplaceDetailPresentationState {
    let isActionLocked: Bool
    let showsOperationProgress: Bool
    let canEditWorkplace: Bool
    let canRefreshAllRepositories: Bool
    let canSyncAllRepositories: Bool
    let canPushAllRepositories: Bool
    let canMergeDefaultBranchIntoCurrent: Bool
    let canSwitchRepositoriesToDefaultBranch: Bool
    let canSwitchRepositoriesToWorkBranch: Bool
    let canOpenDirectory: Bool
    let canDeleteWorkplace: Bool
    let editHelp: String
    let refreshHelp: String
    let syncHelp: String
    let pushHelp: String
    let mergeDefaultBranchHelp: String
    let switchDefaultBranchHelp: String
    let switchWorkBranchHelp: String
    let deleteHelp: String

    init(
        actionState: WorkplaceActionState,
        isPerformingAction: Bool
    ) {
        let isActionLocked = isPerformingAction || actionState.isBusy
        let normalizedWorkBranch = actionState.workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasConfiguredWorkBranch = normalizedWorkBranch.isEmpty == false

        self.isActionLocked = isActionLocked
        showsOperationProgress = isActionLocked
        canEditWorkplace = !isActionLocked
        canRefreshAllRepositories = actionState.hasLocalRepositories && !isActionLocked
        canSyncAllRepositories = actionState.hasPullableRepositories && !isActionLocked
        canPushAllRepositories = actionState.hasLocalRepositories && !isActionLocked
        canMergeDefaultBranchIntoCurrent = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToDefaultBranch = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToWorkBranch =
            actionState.hasLocalRepositories &&
            hasConfiguredWorkBranch &&
            !isActionLocked
        canOpenDirectory = actionState.canOpenDirectory
        canDeleteWorkplace = !isActionLocked
        editHelp = isActionLocked ? "工作区操作进行中" : "编辑工作区名称、分支和仓库配置"
        refreshHelp = isActionLocked ? "工作区操作进行中" : "重新读取所有仓库的本地 Git 状态"
        syncHelp = isActionLocked ? "工作区操作进行中" : "Pull 所有仓库：从远端拉取最新代码并合并到当前分支"
        pushHelp = isActionLocked ? "工作区操作进行中" : "Push 所有仓库：将未推送的提交推送到远端"
        mergeDefaultBranchHelp = isActionLocked ? "工作区操作进行中" : "合并所有仓库的默认分支到当前分支（等同于 git merge main）"
        switchDefaultBranchHelp = isActionLocked ? "工作区操作进行中" : "切到默认分支：将所有仓库切到各自配置的默认分支（如 main/master）"
        switchWorkBranchHelp =
            isActionLocked
            ? "工作区操作进行中"
            : hasConfiguredWorkBranch
                ? "切到工作分支：将所有仓库切到 \(normalizedWorkBranch)"
                : "请先在编辑中配置工作分支名称"
        deleteHelp = isActionLocked ? "工作区操作进行中" : "删除工作区及其本地文件目录"
    }
}

/// 详情页长驻任务读取的「本地目录」镜像。
///
/// 视图结构体是值类型:轮询/分支加载这类长驻闭包捕获的是首帧拷贝,拷贝上的
/// `syncStates` 永远是启动瞬间的快照;镜像存 @State(外部存储),闭包里读到的是
/// 当前值。镜像内容由本纯函数从最新的 syncStates 求值,便于单测。
struct WorkplaceDetailLocalDirectoryMirror: Equatable {
    /// 含本地目录的仓库状态:分支加载只取这些。
    let localDirectoryStates: [RepositorySyncState]
    /// 是否存在任一本地仓库:为空时轮询心跳与分支快照整体跳过。
    let hasAnyLocalDirectory: Bool

    init(syncStates: [RepositorySyncState]) {
        let locals = syncStates.filter(\.hasLocalDirectory)
        localDirectoryStates = locals
        hasAnyLocalDirectory = locals.isEmpty == false
    }
}

struct WorkplaceDeleteConfirmationState: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    /// `directoryPath` 为触发时刻的磁盘探测结果(existingDirectoryPath),
    /// 不在 init 里做 stat:本状态此前被 body 内的 .alert 直接消费,
    /// 一次渲染一次 fileExists 卡主线程,现在由调用方在按钮动作里探测一次。
    init(
        workplace: Workplace,
        directoryPath: String?
    ) {
        title = "删除 \(workplace.name)"
        confirmLabel = "确认删除"

        if let directoryPath {
            message = """
            将删除工作区记录，并删除本地目录中的所有文件。
            目录：\(directoryPath)
            此操作不可撤销。
            """
        } else {
            message = "将删除工作区记录，此操作不可撤销。"
        }
    }
}

struct WorkplaceRepositoryDeleteConfirmationState: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    /// 同 WorkplaceDeleteConfirmationState:`directoryPath` 由调用方在
    /// 触发时刻探测后传入,init 保持纯内存构造。
    init(
        repositoryName: String,
        localPath: String,
        directoryPath: String?
    ) {
        title = "删除 \(repositoryName)"
        confirmLabel = "确认删除"

        if let directoryPath {
            message = """
            将从当前工作区移除该仓库，并删除本地目录中的所有文件。
            目录：\(directoryPath)
            此操作不可撤销。
            """
        } else {
            message = "将从当前工作区移除该仓库，此操作不可撤销。"
        }
    }
}

/// "中止合并/变基"二次确认弹窗文案。操作类型未知时退化为通用文案。
struct WorkplaceRepositoryAbortConfirmationState: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    init(operation: GitInterruptedOperation?) {
        let displayName = operation?.displayName ?? "当前操作"
        title = "中止\(displayName)"
        confirmLabel = "确认中止"
        message = "将丢弃进行中的\(displayName)与已做的冲突解决，仓库回到操作开始前的状态。已提交的内容不受影响。"
    }
}

struct WorkplaceRepositoryBranchPillState: Equatable {
    let title: String
    let quickHelp: String
    let isDefault: Bool

    init?(
        currentBranch: String?,
        defaultBranch: String?,
        hasAvailableBranches: Bool
    ) {
        let normalizedCurrentBranch = currentBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalizedCurrentBranch.isEmpty == false else { return nil }

        let normalizedDefaultBranch = defaultBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isDefault = normalizedCurrentBranch == normalizedDefaultBranch
        title = normalizedCurrentBranch
        quickHelp = hasAvailableBranches ? "当前分支" : "当前分支，暂无可切换的本地分支"
    }
}

/// 分支切换 popover 远端分支区的展示状态:远端分支名单的展示辅助。
/// 本地已有的不再剔除——远端页签应如实反映远端有什么,本地已有的点击即切换本地分支。
struct BranchSwitchRemotePresentationState: Equatable {
    let remoteBranchNames: [String]

    /// 远端分支的展示名:带 origin/ 前缀,与本地远端跟踪引用、对比弹窗的叫法一致。
    func displayName(for remoteBranch: String) -> String {
        "origin/" + remoteBranch
    }

    /// 由展示名还原切换用的分支名(git 侧仍按裸名 + --track 回退处理)。
    func branchName(fromDisplayName displayName: String) -> String {
        displayName.hasPrefix("origin/") ? String(displayName.dropFirst("origin/".count)) : displayName
    }

    /// `remoteBranches` 为 nil(尚未加载)时结果为空,由调用方结合加载态展示。
    /// 输入须已在加载时归一排序(见 `BranchListNormalization`);这里只做轻量去重,
    /// 不再排序——上千分支的本地化排序放进每次 body 求值会卡死主线程。
    init(remoteBranches: [String]?) {
        guard let remoteBranches else {
            remoteBranchNames = []
            return
        }
        var seen = Set<String>()
        remoteBranchNames = remoteBranches
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// 分支对比列表的展示状态:按关键词过滤;列表高度固定(与切换分支弹窗同一套
/// 尺寸恒定策略,切页签/搜索不跳动);高度常量与切换分支弹窗一致。
struct CompareBranchListPresentationState: Equatable {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String
    let listHeight: CGFloat

    init(branches: [String], searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredBranches = query.isEmpty
            ? branches
            : branches.filter { BranchSearch.matches($0, query: query) }

        if branches.isEmpty {
            emptyTitle = "暂无可对比的分支"
            emptySubtitle = ""
        } else if filteredBranches.isEmpty {
            emptyTitle = "未找到匹配分支"
            emptySubtitle = "试试分支名中的关键词。"
        } else {
            emptyTitle = ""
            emptySubtitle = ""
        }

        listHeight = BranchSwitchListPresentationState.fixedListHeight
    }
}

/// 分支切换 popover 的页签来源。
enum BranchSwitchListSource: Equatable {
    case local
    case remote
}

/// 分支搜索匹配:子串命中,或查询词是分支名的子序列(跳字也算)。
/// 习惯打分支名尾段缩写(如 "fck" 命中 "feature/checkout"),
/// 子序列规则在常规分支数量级下开销可忽略,故不加长度阈值。
enum BranchSearch {
    static func matches(_ branch: String, query: String) -> Bool {
        guard query.isEmpty == false else { return true }
        if branch.localizedCaseInsensitiveContains(query) { return true }
        let haystack = Array(branch.lowercased())
        let needle = Array(query.lowercased())
        var index = 0
        for character in haystack {
            if character == needle[index] {
                index += 1
                if index == needle.count { return true }
            }
        }
        return false
    }
}

/// 分支切换 popover 列表的展示状态:按来源(本地分支 / 远端独有分支)与关键词过滤。
/// 列表高度为固定值(与分支数、页签、搜索词均无关):弹窗尺寸恒定,
/// 切页签/搜索/远端加载都不跳动;超出部分在列表内滚动,空态/少量分支时底部留白。
struct BranchSwitchListPresentationState: Equatable {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String
    /// 列表固定高度;用显式数值驱动,内容变化时 popover 能跟随重新布局。
    let listHeight: CGFloat

    static let rowHeight: CGFloat = 30
    /// 固定列表高度:恰好 5 行(rowHeight 30 × 5),超出在列表内滚动;
    /// 连同页签与新建输入行,popover 整体保持紧凑恒定。
    static let fixedListHeight: CGFloat = 150

    init(
        localBranches: [String],
        remoteBranchNames: [String]?,
        source: BranchSwitchListSource,
        searchText: String
    ) {
        let candidates: [String]
        let displayCandidates: [String]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .local:
            candidates = localBranches
            displayCandidates = candidates
        case .remote:
            // 远端名单须已归一排序(BranchListNormalization),此处直接使用。
            let allRemote = remoteBranchNames ?? []
            candidates = allRemote
            // 远端行展示 origin/ 前缀名,搜索剥掉前缀再匹配:
            // 搜 "feat" 与 "origin/feat" 都能命中。
            displayCandidates = allRemote.map { "origin/\($0)" }
        }
        // 远端页签的搜索剥掉 origin/ 前缀再匹配:
        // 行展示的是前缀名,搜 "origin/checkout" 与 "checkout" 应命中同一分支。
        var matchQuery = query
        if source == .remote, matchQuery.hasPrefix("origin/") {
            matchQuery = String(matchQuery.dropFirst("origin/".count))
        }
        filteredBranches = matchQuery.isEmpty
            ? displayCandidates
            : displayCandidates.filter { BranchSearch.matches($0, query: matchQuery) }

        if candidates.isEmpty {
            switch source {
            case .local:
                emptyTitle = "暂无可切换的本地分支"
                emptySubtitle = ""
            case .remote:
                emptyTitle = "远端没有分支"
                emptySubtitle = "如远端刚推送了新分支，可点击重试重新获取"
            }
        } else if filteredBranches.isEmpty {
            emptyTitle = "未找到匹配分支"
            emptySubtitle = "试试分支名中的关键词。"
        } else {
            emptyTitle = ""
            emptySubtitle = ""
        }

        // 高度固定,与分支数/页签/搜索词无关:面板尺寸恒定不跳动。
        listHeight = Self.fixedListHeight
    }
}

/// 溢出菜单/右键菜单尾段的分组渲染顺序:网页动作(仅未克隆时头部独立组)
/// → 本地动作组 → 删除分隔线 → 删除。
/// 顺序并入纯值,由视图按数组渲染(ForEach)而不是靠 ViewBuilder 里的物理摆放:
/// 已克隆仓库的网页动作由本地动作组内的插槽渲染(分支比较之后、与 Stash 块
/// 分开),.webActions 头部组仅未克隆(本地组缺席)时兜底渲染——菜单里恒出现
/// 一次,不会重复。测试断言的是这层纯值顺序语义;视图层 case 与函数体的
/// 对应关系、ForEach 的摆放不在纯值断言的覆盖范围内,靠 review 保证(项目惯例不测渲染)。
enum WorkplaceRepositoryRowMenuGroup: Hashable {
    case webActions
    case localActions
    case primaryDivider
    case delete
}

struct WorkplaceRepositoryRowPresentationState {
    let canRetryClone: Bool
    let canRefreshStatus: Bool
    let canPullLatest: Bool
    let canPushToRemote: Bool
    let canOpenLocalActions: Bool
    /// 在浏览器打开仓库:只依赖配置的远端地址,不要求本地目录存在,
    /// 未克隆的仓库同样要在菜单里保留这条唯一直达远端网页的入口。
    let canOpenRepositoryWeb: Bool
    let canDeleteRepository: Bool
    let canCreateMergeRequest: Bool
    let canSwitchBranch: Bool
    let canStashChanges: Bool
    let canViewChanges: Bool
    /// 存在冲突文件且操作可执行时,才展示"中止合并/变基"入口。
    let canAbortInterruptedOperation: Bool
    let visibleErrorMessage: String?
    /// 菜单尾段的分组渲染顺序(见 WorkplaceRepositoryRowMenuGroup):
    /// 视图按此数组渲染,顺序即分组语义,可被纯值测试断言。
    let menuGroups: [WorkplaceRepositoryRowMenuGroup]

    init(
        syncState: RepositorySyncState,
        hasRetryRepository: Bool,
        hasPullRepository: Bool,
        allowsDeleteRepository: Bool,
        actionsDisabled: Bool,
        hasRepositoryConfig: Bool = false,
        hasUncommittedChanges: Bool? = nil,
        hasConflicts: Bool? = nil
    ) {
        canRetryClone =
            syncState.status == .failed &&
            hasRetryRepository &&
            !actionsDisabled
        canRefreshStatus = syncState.hasLocalDirectory && !actionsDisabled
        canPullLatest =
            syncState.status == .success &&
            hasPullRepository &&
            syncState.hasLocalDirectory &&
            !actionsDisabled
        canOpenLocalActions = syncState.hasLocalDirectory
        canOpenRepositoryWeb = hasRepositoryConfig
        canPushToRemote = canOpenLocalActions && !actionsDisabled
        canDeleteRepository = allowsDeleteRepository && !actionsDisabled
        canCreateMergeRequest = canOpenLocalActions && !actionsDisabled
        // 各动作独立从自身条件推导,不做链式别名:此前
        // `canSwitchBranch = canCreateMergeRequest`、`canViewChanges = canStashChanges`
        // 把语义无关的动作绑死——冲突态下 Stash 被 git 拒绝本应禁用 Stash,
        // 却连带禁掉了"查看改动",而冲突时恰恰最需要看 diff。
        canSwitchBranch = canOpenLocalActions && !actionsDisabled
        // 状态未知(nil)时先禁用,快照加载完成后自动恢复;干净工作区无需 Stash。
        // 冲突未解决时 git 拒绝 stash,冲突态下同样禁用入口。
        canStashChanges =
            canOpenLocalActions &&
            !actionsDisabled &&
            hasUncommittedChanges == true &&
            hasConflicts != true
        // "查看改动"同理:没有未提交改动时无可查看的 diff,直接置灰;
        // 但冲突文件本身就是"未提交改动",查看 diff 在冲突态必须可用。
        canViewChanges =
            canOpenLocalActions &&
            !actionsDisabled &&
            hasUncommittedChanges == true
        canAbortInterruptedOperation =
            canOpenLocalActions &&
            !actionsDisabled &&
            hasConflicts == true
        let trimmedError = syncState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleErrorMessage =
            syncState.status == .failed && !trimmedError.isEmpty
            ? trimmedError
            : nil
        // 删除分隔线的出现口径沿用原 showsPrimaryActionMenuItems:重试/拉取/
        // 本地动作/网页动作任一可见才画线,避免删除前留一段悬空线。
        let showsPrimaryActionMenuItems =
            (syncState.status == .failed && hasRetryRepository) ||
            (syncState.status == .success && hasPullRepository && syncState.hasLocalDirectory) ||
            canOpenLocalActions ||
            canOpenRepositoryWeb
        var groups: [WorkplaceRepositoryRowMenuGroup] = []
        // 网页动作只依赖配置的远端地址,不要求本地目录存在:已克隆时由本地组
        // 内插槽(分支比较后)渲染,头部组不再重复;未克隆时本地组缺席,头部
        // 独立组兜底——保证菜单里恒出现一次。
        if canOpenRepositoryWeb, !canOpenLocalActions { groups.append(.webActions) }
        if canOpenLocalActions { groups.append(.localActions) }
        if showsPrimaryActionMenuItems { groups.append(.primaryDivider) }
        groups.append(.delete)
        menuGroups = groups
    }
}

enum WorkplaceDetailFeedbackFactory {
    static func actionError(action: String, error: Error) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionError(action: action, error: error)
    }

    static func retryClone(
        repositoryName: String,
        syncState: RepositorySyncState?
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.repositoryActionResult(
            repositoryName: repositoryName,
            syncState: syncState,
            successMessage: "已重新克隆 \(repositoryName)",
            fallbackFailureMessage: "重新克隆 \(repositoryName) 失败"
        )
    }

    static func syncRepository(
        repositoryName: String,
        result: RepositoryPullResult,
        syncState: RepositorySyncState?,
        outcome: GitPullAllBranchesOutcome? = nil
    ) -> CCSpaceFeedback {
        var feedback: CCSpaceFeedback
        if result.failedCount == 0 && result.successCount == 0 && result.skippedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 未关联远端分支，已跳过同步"
            )
        } else {
            feedback = CCSpaceFeedbackFactory.repositoryActionResult(
                repositoryName: repositoryName,
                syncState: syncState,
                successMessage: "已同步 \(repositoryName)",
                fallbackFailureMessage: "同步 \(repositoryName) 失败"
            )
        }
        if let outcome, let details = BranchPullOutcomeFormatter.detailsForSingleRepository(outcome) {
            feedback.details = details
        }
        return feedback
    }

    static func pushRepository(
        repositoryName: String,
        outcome: RepositoryPushOutcome,
        syncState: RepositorySyncState?
    ) -> CCSpaceFeedback {
        switch outcome {
        case .pushed:
            return CCSpaceFeedbackFactory.repositoryActionResult(
                repositoryName: repositoryName,
                syncState: syncState,
                successMessage: "已推送 \(repositoryName)",
                fallbackFailureMessage: "推送 \(repositoryName) 失败"
            )
        case .skipped:
            return CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 没有需要推送的提交"
            )
        }
    }

    static func switchBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已切换 \(repositoryName) 到 \(branch)")
    }

    static func switchRepositoryToDefaultBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已将 \(repositoryName) 切换到默认分支 \(branch)")
    }

    static func switchRepositoryToWorkBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已将 \(repositoryName) 切换到工作分支 \(branch)")
    }

    static func createBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已在 \(repositoryName) 创建并切换到 \(branch)")
    }

    static func deleteBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName) 的本地分支 \(branch)")
    }

    static func deleteBranchWithRemote(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName) 的本地分支 \(branch) 与远端分支 origin/\(branch)")
    }

    static func deleteRemoteBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName) 的远端分支 origin/\(branch)")
    }

    static func stashChanges(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已 Stash \(repositoryName) 的改动")
    }

    static func popStash(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已恢复 \(repositoryName) 的 Stash")
    }

    static func dropStash(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName) 的 Stash")
    }

    static func abortInterruptedOperation(
        repositoryName: String,
        operation: GitInterruptedOperation
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已中止 \(repositoryName) 的\(operation.displayName)")
    }

    static func openMergeRequest(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已打开 \(repositoryName) 的 MR 创建页")
    }

    static func deleteRepository(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已从工作区删除 \(repositoryName)")
    }

    static func refreshRepositoryStatus(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已刷新 \(repositoryName) 状态")
    }

    static func refreshAllRepositoryStatuses(
        repositoryCount: Int
    ) -> CCSpaceFeedback {
        guard repositoryCount > 0 else {
            return CCSpaceFeedback(
                style: .info,
                message: "没有可刷新的本地仓库"
            )
        }
        return CCSpaceFeedbackFactory.actionSuccess("已刷新 \(repositoryCount) 个仓库状态")
    }

    static func mergeRepositoryDefaultBranchIntoCurrent(
        repositoryName: String,
        outcome: GitMergeDefaultBranchOutcome
    ) -> CCSpaceFeedback {
        switch outcome {
        case .merged:
            return CCSpaceFeedbackFactory.actionSuccess("已将默认分支代码合并到 \(repositoryName)")
        case .skipped:
            return CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 当前已在默认分支，已跳过合并"
            )
        }
    }

    static func switchAllToDefaultBranch(
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        var feedback = batchSwitchBranches(
            result: result,
            successMessage: "已将 \(result.successCount) 个仓库切换到默认分支",
            mixedMessage: "切换到默认分支完成，\(result.successCount) 个成功，\(result.failedCount) 个失败",
            failureMessage: "切换到默认分支失败，\(result.failedCount) 个仓库失败"
        )
        feedback.details = failedNamesDetails(result.failedNames)
        return feedback
    }

    static func switchAllToWorkBranch(
        branch: String,
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        var feedback = batchSwitchBranches(
            result: result,
            successMessage: "已将 \(result.successCount) 个仓库切换到工作分支 \(branch)",
            mixedMessage: "切换到工作分支 \(branch) 完成，\(result.successCount) 个成功，\(result.failedCount) 个失败",
            failureMessage: "切换到工作分支 \(branch) 失败，\(result.failedCount) 个仓库失败"
        )
        feedback.details = failedNamesDetails(result.failedNames)
        return feedback
    }

    static func mergeDefaultBranchIntoCurrent(
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        var feedback: CCSpaceFeedback
        if result.failedCount > 0 && (result.successCount > 0 || result.skippedCount > 0 || result.cancelledCount > 0) {
            feedback = CCSpaceFeedback(
                style: .warning,
                message: "合并默认分支完成，\(result.successCount) 个成功，\(result.skippedCount) 个跳过，\(result.failedCount) 个失败"
                    + cancelledSuffix(result.cancelledCount)
            )
        } else if result.failedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .error,
                message: "合并默认分支失败，\(result.failedCount) 个仓库失败" + cancelledSuffix(result.cancelledCount)
            )
        } else if result.successCount > 0 && result.skippedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .success,
                message: "合并默认分支完成，\(result.successCount) 个成功，\(result.skippedCount) 个跳过"
                    + cancelledSuffix(result.cancelledCount)
            )
        } else if result.skippedCount > 0 && result.cancelledCount > 0 {
            // 取消与业务跳过分开表述,不再把取消混进"已跳过"。
            feedback = CCSpaceFeedback(
                style: .info,
                message: "已跳过 \(result.skippedCount) 个默认分支仓库，\(result.cancelledCount) 个仓库被取消"
            )
        } else if result.skippedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "已跳过 \(result.skippedCount) 个默认分支仓库"
            )
        } else if result.successCount == 0 && result.cancelledCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "批量合并已取消（\(result.cancelledCount) 个仓库未执行）"
            )
        } else {
            feedback = CCSpaceFeedbackFactory.actionSuccess(
                "已将默认分支代码合并到 \(result.successCount) 个仓库" + cancelledSuffix(result.cancelledCount)
            )
        }
        feedback.details = failedNamesDetails(result.failedNames)
        return feedback
    }

    static func syncAll(
        result: RepositoryPullResult
    ) -> CCSpaceFeedback {
        var feedback = CCSpaceFeedbackFactory.bulkSyncSummary(
            successCount: result.successCount,
            failedCount: result.failedCount,
            skippedCount: result.skippedCount
        )
        let failedDetails = failedNamesDetails(result.failedNames)
        let branchDetails = BranchPullOutcomeFormatter.detailsForBulk(result.branchSummaries)
        feedback.details = [failedDetails, branchDetails].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        return feedback
    }

    static func pushAll(
        result: RepositoryPushResult
    ) -> CCSpaceFeedback {
        var feedback: CCSpaceFeedback
        if result.failedCount > 0 && result.successCount > 0 {
            feedback = CCSpaceFeedback(
                style: .warning,
                message: bulkPushMessage(
                    successCount: result.successCount,
                    failedCount: result.failedCount,
                    skippedCount: result.skippedCount
                ) + cancelledSuffix(result.cancelledCount)
            )
        } else if result.failedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .error,
                message: (result.skippedCount > 0
                    ? "推送失败，\(result.failedCount) 个失败，\(result.skippedCount) 个跳过"
                    : "推送失败，\(result.failedCount) 个仓库失败") + cancelledSuffix(result.cancelledCount)
            )
        } else if result.successCount > 0 && result.skippedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "已推送 \(result.successCount) 个仓库，跳过 \(result.skippedCount) 个"
                    + cancelledSuffix(result.cancelledCount)
            )
        } else if result.successCount > 0 && result.cancelledCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "已推送 \(result.successCount) 个仓库" + cancelledSuffix(result.cancelledCount)
            )
        } else if result.skippedCount > 0 && result.cancelledCount > 0 {
            // 取消与业务跳过分开表述,不再把"全部被取消"说成"没有需要推送的仓库"。
            feedback = CCSpaceFeedback(
                style: .info,
                message: "已跳过 \(result.skippedCount) 个仓库，\(result.cancelledCount) 个仓库被取消"
            )
        } else if result.skippedCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "没有需要推送的仓库"
            )
        } else if result.cancelledCount > 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "批量推送已取消（\(result.cancelledCount) 个仓库未执行）"
            )
        } else if result.successCount == 0 {
            feedback = CCSpaceFeedback(
                style: .info,
                message: "没有可推送的仓库"
            )
        } else {
            feedback = CCSpaceFeedbackFactory.actionSuccess("已推送 \(result.successCount) 个仓库")
        }
        feedback.details = failedNamesDetails(result.failedNames)
        return feedback
    }

    private static func batchSwitchBranches(
        result: WorkplaceBulkBranchSwitchResult,
        successMessage: String,
        mixedMessage: String,
        failureMessage: String
    ) -> CCSpaceFeedback {
        if result.failedCount > 0 && (result.successCount > 0 || result.skippedCount > 0 || result.cancelledCount > 0) {
            return CCSpaceFeedback(style: .warning, message: mixedMessage + cancelledSuffix(result.cancelledCount))
        }
        if result.failedCount > 0 {
            return CCSpaceFeedback(style: .error, message: failureMessage + cancelledSuffix(result.cancelledCount))
        }
        if result.successCount == 0 && result.skippedCount == 0 && result.cancelledCount > 0 {
            // 全部被取消:如实说"已取消",不能谎报"所有仓库已在目标分支"。
            return CCSpaceFeedback(
                style: .info,
                message: "批量切换分支已取消（\(result.cancelledCount) 个仓库未执行）"
            )
        }
        if result.successCount == 0 && result.skippedCount > 0 {
            if result.cancelledCount > 0 {
                // 跳过与取消混在一起时,取消部分要单列出来。
                return CCSpaceFeedback(
                    style: .info,
                    message: "已跳过 \(result.skippedCount) 个仓库，\(result.cancelledCount) 个仓库被取消"
                )
            }
            return CCSpaceFeedback(style: .info, message: "所有仓库已在目标分支")
        }
        return CCSpaceFeedbackFactory.actionSuccess(successMessage + cancelledSuffix(result.cancelledCount))
    }

    /// 汇总文案统一追加"已取消"说明:取消(等锁时被中断)与业务跳过口径不同,需分开表述。
    private static func cancelledSuffix(_ cancelledCount: Int) -> String {
        cancelledCount > 0 ? "，\(cancelledCount) 个已取消" : ""
    }

    private static func bulkPushMessage(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int
    ) -> String {
        if skippedCount > 0 {
            return "推送完成，\(successCount) 个成功，\(failedCount) 个失败，\(skippedCount) 个跳过"
        }
        return "推送完成，\(successCount) 个成功，\(failedCount) 个失败"
    }

    private static func failedNamesDetails(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "失败仓库：" + names.joined(separator: "、")
    }
}

/// 目录存在性探测:路径去空白后非空且在盘上是目录时返回该路径,否则 nil。
/// 注意:这是磁盘 stat,绝不能放进 body 求值路径——调用点必须收敛到
/// 用户动作(如删除按钮)触发的一刻(见 P1-11)。
func existingDirectoryPath(_ path: String) -> String? {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedPath.isEmpty == false else { return nil }

    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
        atPath: trimmedPath,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        return nil
    }

    return trimmedPath
}

enum WorkplaceRepositorySorting {
    static func sortRepositorySyncStates(
        _ states: [RepositorySyncState],
        pinnedRepositoryIDs: [UUID]
    ) -> [RepositorySyncState] {
        let pinnedSet = Set(pinnedRepositoryIDs)
        return states.sorted { lhs, rhs in
            let lp = pinnedSet.contains(lhs.repositoryID)
            let rp = pinnedSet.contains(rhs.repositoryID)
            if lp != rp { return lp && !rp }
            let lhsName = URL(fileURLWithPath: lhs.localPath).lastPathComponent
            let rhsName = URL(fileURLWithPath: rhs.localPath).lastPathComponent
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
    }
}

enum BranchPullOutcomeFormatter {
    /// Renders non-trivial entries of `outcome.otherBranchOutcomes`.
    /// Returns nil when there is nothing worth showing (all `.alreadyUpToDate` or empty).
    /// `currentBranchOutcome` is intentionally NOT listed here — the repo-level status
    /// already reflects it via top-level success/failure counters and `failedNames`.
    static func detailsForSingleRepository(_ outcome: GitPullAllBranchesOutcome) -> String? {
        let lines = nonTrivialLines(outcome.otherBranchOutcomes)
        guard lines.isEmpty == false else { return nil }
        return (["其他分支："] + lines.map { "  " + $0 }).joined(separator: "\n")
    }

    /// Renders multi-repo details: each repo whose otherBranchOutcomes has non-trivial entries
    /// becomes a "<repo>:" block. Repos with only trivial entries are omitted entirely.
    static func detailsForBulk(_ summaries: [RepositoryBranchPullOutcomeSummary]) -> String? {
        let blocks: [String] = summaries.compactMap { summary in
            let lines = nonTrivialLines(summary.outcome.otherBranchOutcomes)
            guard lines.isEmpty == false else { return nil }
            return ([summary.repositoryName + "："] + lines.map { "  " + $0 }).joined(separator: "\n")
        }
        guard blocks.isEmpty == false else { return nil }
        return blocks.joined(separator: "\n")
    }

    private static func nonTrivialLines(_ outcomes: [GitBranchPullOutcome]) -> [String] {
        outcomes.compactMap { outcome in
            switch outcome.status {
            case .alreadyUpToDate:
                return nil
            case .pulled:
                return "\(outcome.branch) 已更新"
            case .skippedDiverged:
                return "\(outcome.branch) 跳过（发散）"
            case .skippedNoUpstream:
                return "\(outcome.branch) 跳过（无 upstream）"
            case .skippedCheckedOutElsewhere:
                return nil
            case .failed:
                if let msg = sanitizedErrorMessage(outcome.errorMessage) {
                    return "\(outcome.branch) 失败：\(msg)"
                }
                return "\(outcome.branch) 失败"
            }
        }
    }

    /// 将多行错误消息合并为一行,避免破坏 details 的缩进结构。
    private static func sanitizedErrorMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(omittingEmptySubsequences: true) { $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
