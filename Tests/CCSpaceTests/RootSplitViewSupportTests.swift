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
