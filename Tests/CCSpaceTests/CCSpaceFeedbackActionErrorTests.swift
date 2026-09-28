import XCTest
@testable import CCSpace

/// actionError 的用户文案必须与仓库行红字同源(WorkplaceRuntimeService 先写
/// UserFacingError.message(for:) 再原样 throw):否则同一次失败,行内是中文、
/// Toast/系统通知却漏出英文原文。
final class CCSpaceFeedbackActionErrorTests: XCTestCase {
    func test_actionErrorLocalizesUnmappedEnglishGitStderr() {
        let error = GitServiceError.commandFailed(
            exitCode: 1,
            stderr: """
            error: Your local changes to the following files would be overwritten by merge:
                a.txt
            Please commit your changes or stash them before you merge.
            """
        )

        let feedback = CCSpaceFeedbackFactory.actionError(action: "Pull 工作区", error: error)

        XCTAssertEqual(feedback.style, .error)
        XCTAssertTrue(
            feedback.message.hasPrefix("Pull 工作区失败："),
            "动作上下文必须保留,实际:\(feedback.message)"
        )
        XCTAssertTrue(
            feedback.message.contains("git 执行失败："),
            "未本地化的英文 stderr 应带 UserFacingError 的中文标识,实际:\(feedback.message)"
        )
        XCTAssertTrue(feedback.message.contains("would be overwritten by merge"))
    }

    func test_actionErrorKeepsChineseGitMessageWithoutExtraPrefix() {
        let error = GitServiceError.operationFailed(message: "无法识别当前分支")

        let feedback = CCSpaceFeedbackFactory.actionError(action: "创建分支", error: error)

        XCTAssertEqual(feedback.message, "创建分支失败：无法识别当前分支")
    }

    func test_actionErrorLocalizesCancellation() {
        let feedback = CCSpaceFeedbackFactory.actionError(action: "同步仓库", error: CancellationError())

        XCTAssertEqual(feedback.message, "同步仓库失败：操作已取消")
    }

    func test_actionErrorPrefixesCocoaSystemError() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be saved."]
        )

        let feedback = CCSpaceFeedbackFactory.actionError(action: "更新仓库", error: error)

        XCTAssertEqual(feedback.message, "更新仓库失败：系统错误：The file couldn’t be saved.")
    }
}
