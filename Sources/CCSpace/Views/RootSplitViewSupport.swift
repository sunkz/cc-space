import SwiftUI

/// 去重是不可撤销的硬删除,提示必须送达;根级横幅同一时刻只能挂一条,已有横幅(`.warning` 约 3 秒后消失、
/// `.error` 需手动关闭)时不能打断,故事件先入队、横幅空出后补放。
struct DeduplicationNoticeQueue: Equatable {
    /// 待展示的累计清理条数;展示前发生的多次事件合并计数,不丢。
    private(set) var pendingCount = 0

    mutating func record(cleanupCount: Int) {
        guard cleanupCount > 0 else { return }
        pendingCount += cleanupCount
    }

    mutating func presentIfIdle(currentBanner: CCSpaceFeedback?) -> CCSpaceFeedback? {
        guard currentBanner == nil, pendingCount > 0 else { return nil }
        let count = pendingCount
        pendingCount = 0
        return CCSpaceFeedback(
            style: .info,
            message: "已自动清理 \(count) 条重复仓库配置",
            details: "同地址/同名只保留一条(优先保留正被工作区引用的那条);清理不可撤销,如需找回请从备份重新导入。"
        )
    }
}

struct WorkplaceCreateSheetPresentation: Identifiable, Equatable {
    let id: UUID
    let seed: WorkplaceCreateSeed

    init(seed: WorkplaceCreateSeed, id: UUID = UUID()) {
        self.id = id
        self.seed = seed
    }
}

struct RootSplitDiskRefreshState {
    let normalizedRootPath: String
    let canScheduleRefresh: Bool
    let shouldInvalidateBranchesAfterRefresh: Bool
    /// 是否顶掉正在跑的刷新任务:用户显式点「刷新」时不能白等下一轮轮询,换新世代重跑(旧任务返回时因世代不符不碰句柄与缓存)。
    /// 但已有一轮**显式**刷新在跑时不再重开:发现阶段要逐个目录起 git 进程,反复点击会不断取消重扫、永远跑不完。
    let shouldTakeOverInFlightRefresh: Bool

    init(
        route: AppRoute,
        selectedWorkplaceID: UUID?,
        scenePhase: ScenePhase,
        rootPath: String,
        force: Bool = false,
        hasForcedRefreshInFlight: Bool = false
    ) {
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)

        normalizedRootPath = trimmedRootPath
        canScheduleRefresh = scenePhase == .active && trimmedRootPath.isEmpty == false
        shouldInvalidateBranchesAfterRefresh = route == .workplaces && selectedWorkplaceID != nil
        shouldTakeOverInFlightRefresh = force
            && canScheduleRefresh
            && hasForcedRefreshInFlight == false
    }
}

@MainActor
final class WorkplaceDetailActionCoordinator: ObservableObject {
    @Published var feedback: CCSpaceFeedback?
    @Published private(set) var isRunningAction = false
    @Published private(set) var branchRefreshSeed = 0
    private var runningTask: Task<Void, Never>?

    /// 宿主注入的"当前选中工作区"读取器:动作开始与写回反馈各取一次,不一致说明用户已切走,
    /// 此时不把 A 的反馈弹在 B 的详情页上(系统通知是另一条通道,照发)。
    var selectedWorkplaceIDProvider: @MainActor () -> UUID? = { nil }

    func invalidateBranches() {
        branchRefreshSeed += 1
    }

    func cancelRunningAction() {
        runningTask?.cancel()
        runningTask = nil
    }

    private func publishFeedback(_ feedback: CCSpaceFeedback?, ownerWorkplaceID: UUID?) {
        guard let feedback else { return }
        guard selectedWorkplaceIDProvider() == ownerWorkplaceID else { return }
        self.feedback = feedback
    }

    func run(
        actionName: String,
        refreshBranches: Bool = false,
        successFeedback: @escaping @MainActor () -> CCSpaceFeedback? = { nil },
        operation: @escaping @MainActor () async throws -> Void
    ) {
        run(
            actionName: actionName,
            refreshBranches: refreshBranches,
            operation: operation,
            successFeedback: { _ in successFeedback() }
        )
    }

    func run<T>(
        actionName: String,
        refreshBranches: Bool = false,
        operation: @escaping @MainActor () async throws -> T,
        successFeedback: @escaping @MainActor (T) -> CCSpaceFeedback? = { _ in nil }
    ) {
        guard isRunningAction == false else { return }

        isRunningAction = true
        feedback = nil
        let ownerWorkplaceID = selectedWorkplaceIDProvider()

        runningTask = Task { @MainActor [weak self] in
            defer {
                self?.isRunningAction = false
                self?.runningTask = nil
                // refreshBranches 必须放在 isRunningAction 复位**之后**:快照重载守卫是 isActionLocked,
                // 先 invalidate 再解锁会让 token 变化触发的 loadBranches 被跳过且无第二次触发,分支对号停在旧值直到 30s 轮询。
                if refreshBranches {
                    self?.invalidateBranches()
                }
            }

            do {
                let result = try await operation()
                // 用户已取消(如批量 pull 完成部分仓库后取消):不弹成功反馈、不发"已完成"通知,避免误导。
                guard Task.isCancelled == false else { return }
                let feedback = successFeedback(result)
                self?.publishFeedback(feedback, ownerWorkplaceID: ownerWorkplaceID)
                NotificationService.shared.notify(actionName: actionName, feedback: feedback)
            } catch is CancellationError {
            } catch {
                self?.publishFeedback(
                    WorkplaceDetailFeedbackFactory.actionError(
                        action: actionName,
                        error: error
                    ),
                    ownerWorkplaceID: ownerWorkplaceID
                )
                NotificationService.shared.send(
                    title: "\(actionName)失败",
                    body: "请查看详情",
                    style: .error
                )
            }
        }
    }
}

enum RootSplitWorkplaceActions {
    @MainActor
    static func runPullRepositories(
        coordinator: WorkplaceDetailActionCoordinator,
        pullRepositories: @escaping @MainActor () async -> RepositoryPullResult
    ) {
        coordinator.run(
            actionName: "Pull 工作区",
            operation: {
                await pullRepositories()
            },
            successFeedback: { result in
                WorkplaceDetailFeedbackFactory.syncAll(result: result)
            }
        )
    }

    @MainActor
    static func runOpenRepositoryWeb(
        coordinator: WorkplaceDetailActionCoordinator,
        resolveRepositoryURL: @escaping @MainActor () async throws -> URL,
        openInBrowser: @escaping @MainActor (URL) throws -> Void
    ) {
        coordinator.run(
            actionName: "打开仓库主页",
            successFeedback: { nil },
            operation: {
                try openInBrowser(await resolveRepositoryURL())
            }
        )
    }

    @MainActor
    static func runCreateMergeRequest(
        coordinator: WorkplaceDetailActionCoordinator,
        repositoryName: String,
        pushRepository: @escaping @MainActor () async throws -> Void,
        resolveMergeRequestURL: @escaping @MainActor () async throws -> URL,
        openInBrowser: @escaping @MainActor (URL) throws -> Void
    ) {
        coordinator.run(
            actionName: "创建 MR",
            refreshBranches: true,
            successFeedback: {
                WorkplaceDetailFeedbackFactory.openMergeRequest(
                    repositoryName: repositoryName
                )
            }
        ) {
            try await pushRepository()
            let mergeRequestURL = try await resolveMergeRequestURL()
            try openInBrowser(mergeRequestURL)
        }
    }

    /// 分支面板行内"向该分支创建 MR"(当前分支为源、指定分支为目标):与工具栏入口的区别是**不先 Push**
    /// (目标分支多半非当前检出,push 无从谈起,未推送时由托管平台页面报错兜底);不改 git 状态,故不触发分支快照重载。
    @MainActor
    static func runCreateMergeRequestForBranch(
        coordinator: WorkplaceDetailActionCoordinator,
        repositoryName: String,
        resolveMergeRequestURL: @escaping @MainActor () async throws -> URL,
        openInBrowser: @escaping @MainActor (URL) throws -> Void
    ) {
        coordinator.run(
            actionName: "创建 MR",
            successFeedback: {
                WorkplaceDetailFeedbackFactory.openMergeRequest(
                    repositoryName: repositoryName
                )
            }
        ) {
            try openInBrowser(await resolveMergeRequestURL())
        }
    }
}
