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
        guard isRunningAction == false else { return }

        isRunningAction = true
        feedback = nil

        runningTask = Task { @MainActor [weak self] in
            defer {
                self?.isRunningAction = false
                self?.runningTask = nil
            }

            do {
                try await operation()
                if refreshBranches {
                    self?.invalidateBranches()
                }
                self?.feedback = successFeedback()
            } catch is CancellationError {
                // 用户取消操作，不显示错误
            } catch {
                self?.feedback = WorkplaceDetailFeedbackFactory.actionError(
                    action: actionName,
                    error: error
                )
            }
        }
    }
}

enum RootSplitWorkplaceActions {
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
