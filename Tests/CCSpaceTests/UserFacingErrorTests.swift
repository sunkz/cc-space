import XCTest
@testable import CCSpace

/// `UserFacingError.message(for:)` 的分支:取消 / GitServiceError / 系统域错误 /
/// 兜底。面向用户的文案必须是简体中文(直接透 `error.localizedDescription` 会把
/// CancellationError 的英文描述、POSIX/Cocoa/NSURLError 英文原文,以及
/// `localizeMessage` 未命中的英文 git stderr 暴露给用户)。
final class UserFacingErrorTests: XCTestCase {
    func test_cancellationErrorReportsChineseCancellationMessage() {
        XCTAssertEqual(UserFacingError.message(for: CancellationError()), "操作已取消")
    }

    func test_gitServiceErrorUsesLocalizedChineseMessage() {
        let error = GitServiceError.commandFailed(
            exitCode: 128,
            stderr: "fatal: could not read Username for 'https://example.com': terminal prompts disabled"
        )
        let message = UserFacingError.message(for: error)
        // git 错误走 localizeMessage 的中文本地化结果(而非英文 stderr 原文),
        // 已是中文时不再叠加前缀。
        XCTAssertEqual(message, "认证信息缺失，请检查 Git 仓库地址或配置 SSH 密钥")
        XCTAssertEqual(message, error.localizedDescription)
    }

    /// localizeMessage 只覆盖已知模式,最常见的失败(本地改动被覆盖等)不在表里,
    /// stderr 原样英文透出——必须补中文标识,不能让英文直接进 `lastError`。
    func test_unmappedEnglishGitStderrGetsChineseMarker() {
        let error = GitServiceError.commandFailed(
            exitCode: 1,
            stderr: """
            error: Your local changes to the following files would be overwritten by merge:
                a.txt
            Please commit your changes or stash them before you merge.
            """
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(
            message.hasPrefix("git 执行失败："),
            "未命中模式的英文 stderr 应带中文标识,实际:\(message)"
        )
        XCTAssertTrue(message.contains("would be overwritten by merge"))
    }

    /// 中英混排:英文报错的路径行是中文文件名(本仓夹具就有 `技术文档.md`)时,
    /// 判据若用"全文含汉字"会误判为"已是中文"而漏掉前缀,纯英文直接上屏。
    /// 结构性判据(是否命中 localizeMessage 模式表)下必须仍补中文标识。
    func test_mixedEnglishStderrWithChineseFilenameStillGetsPrefix() {
        let error = GitServiceError.commandFailed(
            exitCode: 1,
            stderr: """
            error: Your local changes to the following files would be overwritten by merge:
                技术文档.md
            Please commit your changes or stash them before you merge.
            """
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(
            message.hasPrefix("git 执行失败："),
            "中英混排的英文 stderr 仍应带中文标识,实际:\(message)"
        )
        XCTAssertTrue(message.contains("技术文档.md"), "中文文件名原文应保留,实际:\(message)")
    }

    /// 防"过度加前缀"的护栏(非前缀存在性的回归锁):自带中文文案不重复加前缀。
    /// 对照组断言同分支下整段英文文案必须补前缀——前缀逻辑被整体移除时本条变红。
    func test_chineseGitOperationErrorIsNotPrefixedTwice() {
        let error = GitServiceError.operationFailed(message: "无法识别当前分支")
        XCTAssertEqual(UserFacingError.message(for: error), "无法识别当前分支")

        let english = GitServiceError.operationFailed(message: "boom")
        let englishMessage = UserFacingError.message(for: english)
        XCTAssertTrue(
            englishMessage.hasPrefix("git 执行失败："),
            "同分支的英文文案必须补中文前缀,实际:\(englishMessage)"
        )
    }

    func test_cocoaDomainErrorGetsSystemErrorPrefix() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.hasPrefix("系统错误："), "Cocoa 域应加中文系统错误前缀,实际:\(message)")
        XCTAssertTrue(message.contains("The file doesn’t exist."))
    }

    func test_posixDomainErrorGetsSystemErrorPrefix() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: "No such file or directory"]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.hasPrefix("系统错误："), "POSIX 域应加中文系统错误前缀,实际:\(message)")
    }

    /// 网络类失败的主力是 NSURLErrorDomain(超时/断网/证书),英文原文同样不能直出。
    func test_urlErrorGetsNetworkErrorPrefix() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.hasPrefix("网络错误："), "NSURLError 域应加中文网络错误前缀,实际:\(message)")
        XCTAssertTrue(message.contains("The request timed out."))
    }

    /// 用户主动取消(-999)渲染成「网络错误：The operation could not be completed…」
    /// 既英文上屏又语义错误,与 CancellationError 同样按「操作已取消」处理。
    func test_urlErrorCancelledReportsChineseCancellationMessage() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "The request was cancelled."]
        )
        XCTAssertEqual(UserFacingError.message(for: error), "操作已取消")
    }

    func test_unknownDomainErrorPassesThroughUnchanged() {
        let error = NSError(
            domain: "SomeCustomDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "自定义错误描述"]
        )
        XCTAssertEqual(UserFacingError.message(for: error), "自定义错误描述")
    }

    /// 未知域的裸 NSError 若只有英文描述,兜底补中文前缀(自带 errorDescription 的
    /// `LocalizedError` 仍原样透出,避免改写各 Service 已定稿的中文文案)。
    func test_unknownDomainEnglishErrorGetsFallbackChinesePrefix() {
        let error = NSError(
            domain: "SomeCustomDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "something went wrong"]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.hasPrefix("操作失败："), "未知域英文描述应补中文前缀,实际:\(message)")
        XCTAssertTrue(message.contains("something went wrong"))
    }

    /// 防"过度改写"的护栏(非前缀存在性的回归锁):自带 errorDescription 的
    /// `LocalizedError` 即便文案是英文也原样透出,避免改写各 Service 已定稿的文案。
    /// 对照组断言同样英文文案的裸 NSError 必须补前缀——前缀逻辑被整体移除时本条变红。
    func test_localizedErrorWithCustomEnglishTextIsNotRewritten() {
        struct AnyLocalizedError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        XCTAssertEqual(UserFacingError.message(for: AnyLocalizedError()), "boom")

        let bare = NSError(
            domain: "SomeCustomDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let bareMessage = UserFacingError.message(for: bare)
        XCTAssertTrue(
            bareMessage.hasPrefix("操作失败："),
            "同文案的裸 NSError 必须补中文前缀,实际:\(bareMessage)"
        )
    }
}
