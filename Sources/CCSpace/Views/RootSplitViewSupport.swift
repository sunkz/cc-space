import SwiftUI

enum RootSplitRuntimeServices {
    @MainActor
    static func makeWorkplaceRuntimeService(
        workplaceStore: WorkplaceStore,
        syncCoordinator: SyncCoordinator,
        settings: AppSettings
    ) -> WorkplaceRuntimeService {
        WorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: syncCoordinator,
            workplaceRootPath: settings.workplaceRootPath
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

    init(
        route: AppRoute,
        selectedWorkplaceID: UUID?,
        scenePhase: ScenePhase,
        rootPath: String
    ) {
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)

        normalizedRootPath = trimmedRootPath
        canScheduleRefresh = scenePhase == .active && trimmedRootPath.isEmpty == false
        shouldInvalidateBranchesAfterRefresh = route == .workplaces && selectedWorkplaceID != nil
    }
}

@MainActor
final class WorkplaceDetailActionCoordinator: ObservableObject {
    @Published var feedback: CCSpaceFeedback?
    @Published private(set) var isRunningAction = false
    @Published private(set) var branchRefreshSeed = 0
    private var runningTask: Task<Void, Never>?

    func invalidateBranches() {
        branchRefreshSeed += 1
    }

    func cancelRunningAction() {
        runningTask?.cancel()
        runningTask = nil
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

    /// 泛型重载:operation 的返回值直接交给 successFeedback,
    /// 调用方无需再用捕获的 `var result` 中转。
    func run<T>(
        actionName: String,
        refreshBranches: Bool = false,
        operation: @escaping @MainActor () async throws -> T,
        successFeedback: @escaping @MainActor (T) -> CCSpaceFeedback? = { _ in nil }
    ) {
        guard isRunningAction == false else { return }

        isRunningAction = true
        feedback = nil

        runningTask = Task { @MainActor [weak self] in
            defer {
                self?.isRunningAction = false
                self?.runningTask = nil
                // refreshBranches 必须放在 isRunningAction 复位**之后**:
                // 快照重载的守卫是 isActionLocked,若先 invalidate 再解锁,
                // token 变化触发的 loadBranches 会被守卫跳过且没有第二次触发
                // (token 不含锁位),分支面板的对号会停在旧值直到 30s 轮询。
                if refreshBranches {
                    self?.invalidateBranches()
                }
            }

            do {
                let result = try await operation()
                // 用户已取消(如批量 pull 完成了部分仓库后取消):
                // 不弹成功反馈、不发"已完成"通知,避免误导。
                guard Task.isCancelled == false else { return }
                let feedback = successFeedback(result)
                self?.feedback = feedback
                // 批量操作完成,无论前后台都发送系统通知。
                NotificationService.shared.notify(actionName: actionName, feedback: feedback)
            } catch is CancellationError {
                // 用户取消操作，不显示错误
            } catch {
                self?.feedback = WorkplaceDetailFeedbackFactory.actionError(
                    action: actionName,
                    error: error
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
        resolveRepositoryURL: @escaping @MainActor () throws -> URL,
        openInBrowser: @escaping @MainActor (URL) throws -> Void
    ) {
        coordinator.run(
            actionName: "打开仓库主页",
            // 浏览器打开即成功反馈,无需 toast;失败由协调器弹错误反馈。
            successFeedback: { nil },
            operation: {
                try openInBrowser(resolveRepositoryURL())
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
}
