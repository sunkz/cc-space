import XCTest
@testable import CCSpace

final class WorkplaceDetailFeedbackFactoryTests: XCTestCase {
    func test_retryCloneReturnsSuccessFeedbackWhenRepositorySyncSucceeds() {
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: "/tmp/blog",
            lastError: nil,
            lastSyncedAt: nil
        )

        let feedback = WorkplaceDetailFeedbackFactory.retryClone(
            repositoryName: "blog",
            syncState: syncState
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已重新克隆 blog")
    }

    func test_syncRepositoryReturnsErrorFeedbackWhenRepositoryFails() {
        let syncState = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .failed,
            localPath: "/tmp/blog",
            lastError: "network error",
            lastSyncedAt: nil
        )

        let feedback = WorkplaceDetailFeedbackFactory.syncRepository(
            repositoryName: "blog",
            result: RepositoryPullResult(successCount: 0, failedCount: 1, skippedCount: 0),
            syncState: syncState
        )

        XCTAssertEqual(feedback.style, .error)
        XCTAssertEqual(feedback.message, "同步 blog 失败：network error")
    }

    func test_syncAllReturnsWarningWhenSuccessAndFailureMixed() {
        let feedback = WorkplaceDetailFeedbackFactory.syncAll(
            result: RepositoryPullResult(successCount: 1, failedCount: 1, skippedCount: 0)
        )

        XCTAssertEqual(feedback.style, .warning)
        XCTAssertEqual(feedback.message, "同步完成，1 个成功，1 个失败")
    }

    func test_pushAllReturnsWarningWhenSuccessAndFailureMixed() {
        let feedback = WorkplaceDetailFeedbackFactory.pushAll(
            result: RepositoryPushResult(successCount: 2, failedCount: 1, skippedCount: 1)
        )

        XCTAssertEqual(feedback.style, .warning)
        XCTAssertEqual(feedback.message, "推送完成，2 个成功，1 个失败，1 个跳过")
    }

    func test_pushAllReturnsInfoWhenEverythingIsSkipped() {
        let feedback = WorkplaceDetailFeedbackFactory.pushAll(
            result: RepositoryPushResult(successCount: 0, failedCount: 0, skippedCount: 2)
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "没有需要推送的仓库")
    }

    func test_pushRepositoryReturnsInfoWhenRepositoryIsSkipped() {
        let feedback = WorkplaceDetailFeedbackFactory.pushRepository(
            repositoryName: "blog",
            outcome: .skipped,
            syncState: nil
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "blog 没有需要推送的提交")
    }

    func test_deleteRepositoryReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.deleteRepository(
            repositoryName: "blog"
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已从工作区删除 blog")
    }

    func test_refreshRepositoryStatusReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.refreshRepositoryStatus(
            repositoryName: "blog"
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已刷新 blog 状态")
    }

    func test_refreshAllRepositoryStatusesReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.refreshAllRepositoryStatuses(
            repositoryCount: 3
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已刷新 3 个仓库状态")
    }

    func test_refreshAllRepositoryStatusesReturnsInfoWhenNoLocalRepositoryExists() {
        let feedback = WorkplaceDetailFeedbackFactory.refreshAllRepositoryStatuses(
            repositoryCount: 0
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "没有可刷新的本地仓库")
    }

    func test_syncRepositoryReturnsInfoFeedbackWhenRepositoryIsSkipped() {
        let feedback = WorkplaceDetailFeedbackFactory.syncRepository(
            repositoryName: "blog",
            result: RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 1),
            syncState: nil
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "blog 当前不是默认分支，已跳过同步")
    }

    func test_switchBranchReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.switchBranch(
            repositoryName: "blog",
            branch: "release/01"
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已切换 blog 到 release/01")
    }

    func test_switchRepositoryToDefaultBranchReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.switchRepositoryToDefaultBranch(
            repositoryName: "blog",
            branch: "main"
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已将 blog 切换到默认分支 main")
    }

    func test_switchRepositoryToWorkBranchReturnsSuccessFeedback() {
        let feedback = WorkplaceDetailFeedbackFactory.switchRepositoryToWorkBranch(
            repositoryName: "blog",
            branch: "01"
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已将 blog 切换到工作分支 01")
    }

    func test_mergeRepositoryDefaultBranchIntoCurrentReturnsInfoWhenSkipped() {
        let feedback = WorkplaceDetailFeedbackFactory.mergeRepositoryDefaultBranchIntoCurrent(
            repositoryName: "blog",
            outcome: .skipped
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "blog 当前已在默认分支，已跳过合并")
    }

    func test_switchAllToDefaultBranchReturnsWarningForMixedResults() {
        let feedback = WorkplaceDetailFeedbackFactory.switchAllToDefaultBranch(
            result: WorkplaceBulkBranchSwitchResult(successCount: 2, failedCount: 1)
        )

        XCTAssertEqual(feedback.style, .warning)
        XCTAssertEqual(feedback.message, "切换到默认分支完成，2 个成功，1 个失败")
    }

    func test_switchAllToWorkBranchReturnsSuccessMessage() {
        let feedback = WorkplaceDetailFeedbackFactory.switchAllToWorkBranch(
            branch: "88",
            result: WorkplaceBulkBranchSwitchResult(successCount: 3, failedCount: 0)
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已将 3 个仓库切换到工作分支 88")
    }

    func test_mergeDefaultBranchIntoCurrentReturnsInfoWhenAllSkipped() {
        let feedback = WorkplaceDetailFeedbackFactory.mergeDefaultBranchIntoCurrent(
            result: WorkplaceBulkBranchSwitchResult(successCount: 0, failedCount: 0, skippedCount: 2)
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "已跳过 2 个默认分支仓库")
    }
}
