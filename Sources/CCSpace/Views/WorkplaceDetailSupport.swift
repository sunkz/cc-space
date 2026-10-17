import AppKit
import Foundation


/// 分支列表"已选置顶"稳定排序:被选中的按原相对顺序排在前,其余紧随其后——两组内部各自稳定,
/// 只有被操作那一行在两组之间移动,点选/取消不会让其他行乱跳。
enum BranchSelectionOrder {
    static func selectedFirst(_ branches: [String], selected: [String]) -> [String] {
        let selectedSet = Set(selected)
        let hits = branches.filter { selectedSet.contains($0) }
        let rest = branches.filter { selectedSet.contains($0) == false }
        return hits + rest
    }
}

/// 分支按"最近活动"排序:最后提交时间新的在前;无时间的保持原顺序(字母序)排在最后——
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

enum WorkplaceSystemActions {
    static func openTerminal(_ terminal: ExternalEditor, at path: String) throws {
        // 与 openInEditor 同一口径:归一化 + 存在性校验,否则空串/失效路径会让 Terminal 静默打开默认目录。
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
        // /usr/bin/open 的告警/错误不面向用户:不接管就会继承父进程 fd(打包成 app 时指向不可写位置)。
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
    let canSwitchRepositoriesToDefaultBranch: Bool
    let canSwitchRepositoriesToWorkBranch: Bool
    let canOpenDirectory: Bool
    let canDeleteWorkplace: Bool
    let editHelp: String
    let refreshHelp: String
    let syncHelp: String
    let pushHelp: String
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
        canSyncAllRepositories = actionState.hasLocalRepositories && !isActionLocked
        canPushAllRepositories = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToDefaultBranch = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToWorkBranch =
            actionState.hasLocalRepositories &&
            hasConfiguredWorkBranch &&
            !isActionLocked
        canOpenDirectory = actionState.canOpenDirectory
        canDeleteWorkplace = !isActionLocked
        editHelp = isActionLocked ? "工作区操作进行中" : "编辑工作区名称、分支和仓库配置"
        refreshHelp = isActionLocked
            ? "工作区操作进行中"
            : "重新读取所有仓库的本地 Git 状态，并纳入目录里新拷入的仓库"
        syncHelp = isActionLocked ? "工作区操作进行中" : "Pull 所有仓库：从远端拉取最新代码并合并到当前分支"
        pushHelp = isActionLocked ? "工作区操作进行中" : "Push 所有仓库：将未推送的提交推送到远端"
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

/// 详情页长驻任务读取的「本地目录」镜像:视图结构体是值类型,轮询/分支加载这类长驻闭包捕获的是首帧拷贝,
/// 拷贝上的 `syncStates` 是冻结快照;镜像存 @State(外部存储),内容由本纯函数从最新 syncStates 求值。
struct WorkplaceDetailLocalDirectoryMirror: Equatable {
    /// 含本地目录的仓库状态:分支加载只取这些。
    let localDirectoryStates: [RepositorySyncState]
    /// 为空时轮询心跳与分支快照整体跳过。
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

    /// `directoryPath` 为触发时刻的磁盘探测结果,不在 init 里做 stat:本状态被 body 内的 `.alert` 直接消费,
    /// 现算等于一次渲染一次主线程 fileExists;由调用方在按钮动作里探测一次。
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

    /// 同 WorkplaceDeleteConfirmationState:`directoryPath` 由调用方在触发时刻探测后传入,init 保持纯内存构造。
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
    let isDefault: Bool

    init?(
        currentBranch: String?,
        defaultBranch: String?
    ) {
        let normalizedCurrentBranch = currentBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalizedCurrentBranch.isEmpty == false else { return nil }

        let normalizedDefaultBranch = defaultBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isDefault = normalizedCurrentBranch == normalizedDefaultBranch
        title = normalizedCurrentBranch
    }
}

/// 远端跟踪引用与裸分支名的换算:面板统一展示裸分支名,而对比模式的"远端"数据来自
/// `refs/remotes`(本身就是 `origin/x` 形式的引用名),两者在这里划清界限。
enum BranchRemoteRef {
    /// `origin/feature/x` → `feature/x`:只去首段 remote 名,分支名自带的 "/" 保留;
    /// 不含 "/"、或去完前缀为空(`origin/`)的输入原样返回——宁可多显示也不留空行。
    static func bareName(ofTrackingRef ref: String) -> String {
        guard let slash = ref.firstIndex(of: "/") else { return ref }
        let bare = String(ref[ref.index(after: slash)...])
        return bare.isEmpty ? ref : bare
    }

    /// 一批跟踪引用里裸名撞车的名字:多 remote 仓库(fork + upstream)下
    /// `origin/main` 与 `fork/main` 都会裸成 `main`,这时不能去前缀。
    static func ambiguousBareNames(ofTrackingRefs refs: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for ref in refs {
            counts[bareName(ofTrackingRef: ref), default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    /// 行展示名:只在"分支对比 + 远端页签"(`showsBareRemoteNames`)下去前缀显示裸名,裸名在这批行里撞车时返回 nil;
    /// 其余场景同样返回 nil——那表示"显示行自身值",不是"显示空"。
    static func displayBranch(
        ofTrackingRef ref: String,
        ambiguousBareNames: Set<String>,
        showsBareRemoteNames: Bool
    ) -> String? {
        guard showsBareRemoteNames else { return nil }
        let bare = bareName(ofTrackingRef: ref)
        return ambiguousBareNames.contains(bare) ? nil : bare
    }
}

struct BranchSwitchRemotePresentationState: Equatable {
    let remoteBranchNames: [String]

    /// 远端名单只做归一与去重(本地已有的不剔除,那条点击即切换)。输入须已在加载时归一排序(见 `BranchListNormalization`),
    /// 这里不再排序——上千分支的本地化排序放进每次 body 求值会卡死主线程。
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

struct CompareBranchListPresentationState: Equatable {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String

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

    }
}

enum BranchSwitchListSource: Equatable {
    case local
    case remote
}

/// 分支搜索匹配:子串命中,或查询词是分支名的子序列(如 "fck" 命中 "feature/checkout");
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

/// 分支切换 popover 列表:按来源(本地 / 远端独有)与关键词过滤。
/// 列表高度固定(与分支数、页签、搜索词均无关),弹窗尺寸恒定,超出在列表内滚动、空态时底部留白。
struct BranchSwitchListPresentationState: Equatable {
    let filteredBranches: [String]
    let emptyTitle: String
    let emptySubtitle: String

    /// 固定列表高度:恰好 5 行 × 30pt;连同页签与新建输入行,popover 整体紧凑恒定。
    static let fixedListHeight: CGFloat = 150

    init(
        localBranches: [String],
        remoteBranchNames: [String]?,
        source: BranchSwitchListSource,
        searchText: String
    ) {
        let candidates: [String]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .local:
            candidates = localBranches
        case .remote:
            // 名单须已归一排序(BranchListNormalization),此处直接使用;展示一律用裸名,
            // 分支面板里不加 origin/ 前缀,本地/远端靠页签区分。
            candidates = remoteBranchNames ?? []
        }
        // 仍容忍用户把 origin/ 打进搜索词:剥掉前缀,让 "origin/checkout" 与 "checkout" 命中同一分支。
        var matchQuery = query
        if source == .remote, matchQuery.hasPrefix("origin/") {
            matchQuery = String(matchQuery.dropFirst("origin/".count))
        }
        filteredBranches = matchQuery.isEmpty
            ? candidates
            : candidates.filter { BranchSearch.matches($0, query: matchQuery) }

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

    }
}

/// 溢出/右键菜单尾段的分组渲染顺序,由视图按数组 ForEach 渲染而不是靠 ViewBuilder 里的物理摆放(顺序可被纯值测试断言):
/// 已克隆仓库的网页动作由本地动作组内的插槽渲染,.webActions 头部组仅未克隆(本地组缺席)时兜底——菜单里恒出现一次。
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
    /// 只依赖配置的远端地址,不要求本地目录存在:未克隆仓库也要保留这条唯一直达远端网页的入口。
    let canOpenRepositoryWeb: Bool
    let canDeleteRepository: Bool
    let canCreateMergeRequest: Bool
    let canSwitchBranch: Bool
    let canStashChanges: Bool
    let canViewChanges: Bool
    let canAbortInterruptedOperation: Bool
    let visibleErrorMessage: String?
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
        // 各动作独立从自身条件推导,不做链式别名:语义无关的动作会因一次条件调整被连带禁用
        // (冲突态下 Stash 被 git 拒绝本应只禁用 Stash,链式别名会连带禁掉"查看改动",而冲突时恰恰最需要看 diff)。
        canSwitchBranch = canOpenLocalActions && !actionsDisabled
        // 状态未知(nil)时先禁用,快照加载完成后自动恢复;干净工作区无需 Stash,冲突未解决时 git 拒绝 stash。
        canStashChanges =
            canOpenLocalActions &&
            !actionsDisabled &&
            hasUncommittedChanges == true &&
            hasConflicts != true
        // 没有未提交改动就无可查看的 diff;但冲突文件本身就是未提交改动,冲突态下"查看改动"必须可用。
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
        // 删除分隔线只在任一主动作可见时画线,避免删除前留一段悬空线。
        let showsPrimaryActionMenuItems =
            (syncState.status == .failed && hasRetryRepository) ||
            (syncState.status == .success && hasPullRepository && syncState.hasLocalDirectory) ||
            canOpenLocalActions ||
            canOpenRepositoryWeb
        var groups: [WorkplaceRepositoryRowMenuGroup] = []
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
        result: WorkplaceBatchOperationResult
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
        result: WorkplaceBatchOperationResult
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
        result: WorkplaceBatchOperationResult
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
            // 取消与业务跳过口径不同,不能把"全部被取消"说成"没有需要推送的仓库"。
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
        result: WorkplaceBatchOperationResult,
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
                // 取消部分要单列,不能并入"跳过"表述。
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
/// 这是磁盘 stat,绝不能放进 body 求值路径——调用点必须收敛到用户动作(如删除按钮)触发的一刻。
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
    /// 只渲染非平凡条目(全 `.alreadyUpToDate` 或为空时返回 nil)。
    /// `currentBranchOutcome` 有意不列:仓库级状态已由顶层成功/失败计数与 `failedNames` 反映。
    static func detailsForSingleRepository(_ outcome: GitPullAllBranchesOutcome) -> String? {
        let lines = nonTrivialLines(outcome.otherBranchOutcomes)
        guard lines.isEmpty == false else { return nil }
        return (["其他分支："] + lines.map { "  " + $0 }).joined(separator: "\n")
    }

    /// 多仓汇总:只列出含非平凡条目的仓库,其余整块省略。
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

