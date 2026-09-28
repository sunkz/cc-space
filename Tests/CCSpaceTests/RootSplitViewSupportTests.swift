import SwiftUI
import XCTest
@testable import CCSpace

private struct RootSplitSupportStubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor ActionInvocationRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
final class RootSplitViewSupportTests: XCTestCase {
    func test_diskRefreshStateSkipsRefreshWhenWindowIsInactive() {
        let state = RootSplitDiskRefreshState(
            route: .workplaces,
            selectedWorkplaceID: UUID(),
            scenePhase: .inactive,
            rootPath: "/tmp/workspaces"
        )

        XCTAssertEqual(state.normalizedRootPath, "/tmp/workspaces")
        XCTAssertFalse(state.canScheduleRefresh)
        XCTAssertTrue(state.shouldInvalidateBranchesAfterRefresh)
    }

    func test_diskRefreshStateSkipsRefreshWhenRootPathMissing() {
        let state = RootSplitDiskRefreshState(
            route: .settings,
            selectedWorkplaceID: nil,
            scenePhase: .active,
            rootPath: "   "
        )

        XCTAssertEqual(state.normalizedRootPath, "")
        XCTAssertFalse(state.canScheduleRefresh)
        XCTAssertFalse(state.shouldInvalidateBranchesAfterRefresh)
    }

    func test_diskRefreshStateRefreshesForActiveWorkplaceSelection() {
        let state = RootSplitDiskRefreshState(
            route: .workplaces,
            selectedWorkplaceID: UUID(),
            scenePhase: .active,
            rootPath: " /tmp/workspaces "
        )

        XCTAssertEqual(state.normalizedRootPath, "/tmp/workspaces")
        XCTAssertTrue(state.canScheduleRefresh)
        XCTAssertTrue(state.shouldInvalidateBranchesAfterRefresh)
    }

    func test_runtimeServiceFactoryPassesTrimmedSettingsRootPath() {
        let fileStore = JSONFileStore(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        let service = RootSplitRuntimeServices.makeWorkplaceRuntimeService(
            workplaceStore: workplaceStore,
            syncCoordinator: SyncCoordinator(gitService: GitService()),
            settings: AppSettings(workplaceRootPath: " /tmp/workspaces ")
        )

        XCTAssertEqual(service.workplaceRootPath, "/tmp/workspaces")
    }

    func test_actionCoordinatorPreventsOverlappingRuns() async {
        let coordinator = WorkplaceDetailActionCoordinator()
        let recorder = ActionInvocationRecorder()
        let firstActionStarted = expectation(description: "first action started")

        coordinator.run(actionName: "同步工作区") {
            await recorder.record()
            firstActionStarted.fulfill()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        coordinator.run(actionName: "推送工作区") {
            await recorder.record()
        }

        await fulfillment(of: [firstActionStarted], timeout: 1)
        let runningCount = await recorder.count
        XCTAssertTrue(coordinator.isRunningAction)
        XCTAssertEqual(runningCount, 1)

        await waitUntil(coordinator.isRunningAction == false)
        let finalCount = await recorder.count
        XCTAssertEqual(finalCount, 1)
    }

    func test_actionCoordinatorPublishesSuccessFeedbackAndRefreshSeed() async {
        let coordinator = WorkplaceDetailActionCoordinator()
        let feedback = CCSpaceFeedback(style: .success, message: "已完成")

        coordinator.run(
            actionName: "切换分支",
            refreshBranches: true,
            successFeedback: { feedback }
        ) {}

        await waitUntil(coordinator.isRunningAction == false)

        XCTAssertEqual(coordinator.feedback, feedback)
        XCTAssertEqual(coordinator.branchRefreshSeed, 1)
    }

    func test_actionCoordinatorPublishesErrorFeedbackOnFailure() async {
        let coordinator = WorkplaceDetailActionCoordinator()

        coordinator.run(actionName: "删除仓库") {
            throw RootSplitSupportStubError(message: "boom")
        }

        await waitUntil(coordinator.isRunningAction == false)

        XCTAssertEqual(
            coordinator.feedback,
            CCSpaceFeedback(style: .error, message: "删除仓库失败：boom")
        )
        XCTAssertEqual(coordinator.branchRefreshSeed, 0)
    }

    func test_runPullRepositoriesPublishesSyncFeedback() async {
        let coordinator = WorkplaceDetailActionCoordinator()

        RootSplitWorkplaceActions.runPullRepositories(
            coordinator: coordinator,
            pullRepositories: {
                RepositoryPullResult(successCount: 2, failedCount: 0, skippedCount: 1)
            }
        )

        await waitUntil(coordinator.isRunningAction == false)

        XCTAssertEqual(
            coordinator.feedback,
            CCSpaceFeedback(style: .info, message: "已同步 2 个仓库，跳过 1 个")
        )
        XCTAssertEqual(coordinator.branchRefreshSeed, 0)
    }

    func test_runCreateMergeRequestRefreshesBranchesAfterSuccess() async throws {
        let coordinator = WorkplaceDetailActionCoordinator()
        let mergeRequestURL = try XCTUnwrap(URL(string: "https://example.com/mr"))
        var pushCount = 0
        var openedURLs: [URL] = []

        RootSplitWorkplaceActions.runCreateMergeRequest(
            coordinator: coordinator,
            repositoryName: "api",
            pushRepository: {
                pushCount += 1
            },
            resolveMergeRequestURL: {
                mergeRequestURL
            },
            openInBrowser: { url in
                openedURLs.append(url)
            }
        )

        await waitUntil(coordinator.isRunningAction == false)

        XCTAssertEqual(pushCount, 1)
        XCTAssertEqual(openedURLs, [mergeRequestURL])
        XCTAssertEqual(
            coordinator.feedback,
            CCSpaceFeedback(style: .success, message: "已打开 api 的 MR 创建页")
        )
        XCTAssertEqual(coordinator.branchRefreshSeed, 1)
    }

    func test_createSheetPresentationKeepsDuplicateSeedSelections() {
        let repositoryID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let seed = WorkplaceCreateSeed(
            name: "aso 副本",
            branch: "feature-skz-aso",
            selectedRepositoryIDs: [repositoryID]
        )

        let presentation = WorkplaceCreateSheetPresentation(seed: seed)

        XCTAssertEqual(presentation.seed, seed)
    }

    func test_createSheetPresentationUsesFreshIdentityForRepeatedSeed() {
        let seed = WorkplaceCreateSeed(
            name: "aso 副本",
            branch: "feature-skz-aso",
            selectedRepositoryIDs: [UUID()]
        )

        let firstPresentation = WorkplaceCreateSheetPresentation(seed: seed)
        let secondPresentation = WorkplaceCreateSheetPresentation(seed: seed)

        XCTAssertNotEqual(firstPresentation.id, secondPresentation.id)
        XCTAssertEqual(firstPresentation.seed, secondPresentation.seed)
    }

    // MARK: - 上次路由恢复(RouteRestoreSupport)

    private func restoreWorkplace(id: UUID) -> Workplace {
        Workplace(
            id: id,
            name: "ios-dev",
            path: "/tmp/ios-dev",
            selectedRepositoryIDs: [],
            createdAt: .now,
            updatedAt: .now
        )
    }

    func test_routeRestoreReturnsExactWorkplaceWhenStillPresent() {
        let workplaceID = UUID()

        let selection = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: "workplaces",
            lastSelectedWorkplaceID: workplaceID.uuidString,
            workplaces: [restoreWorkplace(id: workplaceID)]
        )

        XCTAssertEqual(selection, RouteRestoreSupport.Selection(route: .workplaces, workplaceID: workplaceID))
    }

    /// 上次在工作区页但工作区已被删:降级到"工作区列表",而不是什么都不做落回默认 .settings。
    func test_routeRestoreFallsBackToWorkplaceListWhenWorkplaceDeleted() {
        let selection = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: "workplaces",
            lastSelectedWorkplaceID: UUID().uuidString,
            workplaces: []
        )

        XCTAssertEqual(selection, RouteRestoreSupport.Selection(route: .workplaces, workplaceID: nil))
    }

    func test_routeRestoreFallsBackToWorkplaceListWhenSelectionMissingOrInvalid() {
        let missingSelection = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: "workplaces",
            lastSelectedWorkplaceID: nil,
            workplaces: []
        )
        XCTAssertEqual(missingSelection, RouteRestoreSupport.Selection(route: .workplaces, workplaceID: nil))

        let invalidUUID = RouteRestoreSupport.restoredSelection(
            lastSelectedRoute: "workplaces",
            lastSelectedWorkplaceID: "not-a-uuid",
            workplaces: []
        )
        XCTAssertEqual(invalidUUID, RouteRestoreSupport.Selection(route: .workplaces, workplaceID: nil))
    }

    func test_routeRestoreReturnsSettingsRouteAndNilForUnusableValues() {
        XCTAssertEqual(
            RouteRestoreSupport.restoredSelection(
                lastSelectedRoute: "settings",
                lastSelectedWorkplaceID: nil,
                workplaces: []
            ),
            RouteRestoreSupport.Selection(route: .settings, workplaceID: nil)
        )
        // 路由缺失/非法(旧版本或手改文件)→ nil,调用方落到默认路由。
        XCTAssertNil(
            RouteRestoreSupport.restoredSelection(
                lastSelectedRoute: nil,
                lastSelectedWorkplaceID: nil,
                workplaces: []
            )
        )
        XCTAssertNil(
            RouteRestoreSupport.restoredSelection(
                lastSelectedRoute: "repositories",
                lastSelectedWorkplaceID: nil,
                workplaces: []
            )
        )
    }

    // MARK: - 恢复结果落地(RouteRestoreSupport.apply)

    /// 降级接线的回归锁:降级到列表页只切路由,绝不回调 onSelectedWorkplaceChange(nil)
    /// (否则 500ms 防抖后 lastSelectedWorkplaceID 被持久化成 nil,单点损坏级联改写
    /// 健康的 settings.json)。apply 改回裸 showRoute 时本测试变红。
    func test_applyDegradedSelectionRoutesWithoutPersistingNilSelection() {
        let model = AppViewModel()
        var persistedRoutes: [AppRoute] = []
        var persistedSelections: [UUID?] = []
        model.onRouteChange = { persistedRoutes.append($0) }
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        RouteRestoreSupport.apply(
            RouteRestoreSupport.Selection(route: .workplaces, workplaceID: nil),
            to: model
        )

        XCTAssertEqual(model.route, .workplaces)
        XCTAssertNil(model.selectedWorkplaceID)
        XCTAssertEqual(persistedRoutes, [.workplaces], "路由镜像照常更新")
        XCTAssertTrue(persistedSelections.isEmpty, "降级不得把 nil 写回 lastSelectedWorkplaceID")
    }

    /// 正常恢复到工作区:选中项照常回写(与降级分支的差异必须存在,否则 apply 恒不通知就锁不住)。
    func test_applyRestoredWorkplaceNotifiesSelectionChange() {
        let model = AppViewModel()
        let workplaceID = UUID()
        var persistedSelections: [UUID?] = []
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        RouteRestoreSupport.apply(
            RouteRestoreSupport.Selection(route: .workplaces, workplaceID: workplaceID),
            to: model
        )

        XCTAssertEqual(model.selectedWorkplaceID, workplaceID)
        XCTAssertEqual(persistedSelections, [workplaceID])
    }

    /// 上次在设置页:仍走默认通知语义(清空选中是事实,与降级分支不同)。
    func test_applySettingsRouteNotifiesSelectionChange() {
        let model = AppViewModel()
        var persistedSelections: [UUID?] = []
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        RouteRestoreSupport.apply(
            RouteRestoreSupport.Selection(route: .settings, workplaceID: nil),
            to: model
        )

        XCTAssertEqual(model.route, .settings)
        XCTAssertEqual(persistedSelections, [nil])
    }

    // MARK: - 去重清理提示(DeduplicationNoticeQueue)

    private let corruptBanner = CCSpaceFeedback(
        style: .warning,
        message: "仓库配置文件曾损坏并已恢复"
    )

    func test_deduplicationNoticePresentsImmediatelyWhenNoBanner() {
        var queue = DeduplicationNoticeQueue()
        queue.record(cleanupCount: 2)

        let feedback = queue.presentIfIdle(currentBanner: nil)

        XCTAssertEqual(feedback?.style, CCSpaceFeedbackStyle.info)
        XCTAssertEqual(feedback?.message, "已自动清理 2 条重复仓库配置")
        XCTAssertEqual(queue.pendingCount, 0, "展示后队列清空")
    }

    /// 触发那一刻已有横幅(损坏恢复 .warning 约 3 秒后才消失、.error 需手动关闭):
    /// 不打断正在展示的提示,去重提示也不得丢失,横幅空出后补放。
    /// 此前直接丢弃且事件不会重放(清理条数不再变化),本启动期再也出不来。
    func test_deduplicationNoticeHeldWhileBannerVisibleThenPresented() {
        var queue = DeduplicationNoticeQueue()
        queue.record(cleanupCount: 3)

        XCTAssertNil(queue.presentIfIdle(currentBanner: corruptBanner), "不打断正在展示的横幅")
        XCTAssertEqual(queue.pendingCount, 3, "事件入队保留,不丢")

        let deferred = queue.presentIfIdle(currentBanner: nil)

        XCTAssertEqual(deferred?.message, "已自动清理 3 条重复仓库配置")
        XCTAssertEqual(queue.pendingCount, 0)
    }

    /// 展示前的多次事件合并计数(同启动期两次去重条数可能相同,各自入队不互相覆盖)。
    func test_deduplicationNoticeAccumulatesEventsUntilPresented() {
        var queue = DeduplicationNoticeQueue()
        queue.record(cleanupCount: 2)
        queue.record(cleanupCount: 2)
        queue.record(cleanupCount: 0)

        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertNil(
            queue.presentIfIdle(currentBanner: corruptBanner),
            "横幅占用时不出队"
        )
        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertEqual(
            queue.presentIfIdle(currentBanner: nil)?.message,
            "已自动清理 4 条重复仓库配置"
        )
        XCTAssertNil(queue.presentIfIdle(currentBanner: nil), "队列已空")
    }

    private func waitUntil(
        _ condition: @autoclosure @escaping () -> Bool,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().timeIntervalSince1970 + Double(timeoutNanoseconds) / 1_000_000_000

        while condition() == false {
            guard Date().timeIntervalSince1970 < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
