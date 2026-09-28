import XCTest
@testable import CCSpace

final class CCSpaceFeedbackFactoryTests: XCTestCase {
    func test_actionSuccessReturnsSuccessFeedback() {
        let feedback = CCSpaceFeedbackFactory.actionSuccess("已新增 blog")

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已新增 blog")
        XCTAssertEqual(feedback.systemImage, "checkmark.circle.fill")
    }

    func test_actionErrorReturnsErrorFeedbackWithActionPrefix() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "network down" }
        }

        let feedback = CCSpaceFeedbackFactory.actionError(
            action: "同步仓库",
            error: StubError()
        )

        XCTAssertEqual(feedback.style, .error)
        XCTAssertEqual(feedback.message, "同步仓库失败：network down")
        XCTAssertEqual(feedback.systemImage, "exclamationmark.triangle.fill")
    }

    func test_repositoryActionResultReturnsErrorWithFallbackWhenSyncStateMissing() {
        let feedback = CCSpaceFeedbackFactory.repositoryActionResult(
            repositoryName: "blog",
            syncState: nil,
            successMessage: "已同步 blog",
            fallbackFailureMessage: "同步 blog 失败"
        )

        XCTAssertEqual(feedback.style, .error)
        XCTAssertEqual(feedback.message, "同步 blog 失败")
    }

    func test_bulkSyncSummaryReturnsSuccessWhenAllRepositoriesSucceed() {
        let feedback = CCSpaceFeedbackFactory.bulkSyncSummary(
            successCount: 3,
            failedCount: 0
        )

        XCTAssertEqual(feedback.style, .success)
        XCTAssertEqual(feedback.message, "已同步 3 个仓库")
    }

    func test_bulkSyncSummaryIncludesSkippedRepositories() {
        let feedback = CCSpaceFeedbackFactory.bulkSyncSummary(
            successCount: 2,
            failedCount: 0,
            skippedCount: 1
        )

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.message, "已同步 2 个仓库，跳过 1 个")
    }

    func test_infoStyleUsesInfoCircleIcon() {
        let feedback = CCSpaceFeedback(style: .info, message: "将新增 1 个仓库")

        XCTAssertEqual(feedback.style, .info)
        XCTAssertEqual(feedback.systemImage, "info.circle.fill")
    }
}
