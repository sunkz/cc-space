import XCTest
import UserNotifications
@testable import CCSpace

/// NotificationService 仅测不触达真实 UNUserNotificationCenter 的部分:
/// NotificationStyle 的纯映射,以及无应用 bundle 的测试进程
/// (bundle id 为 com.apple.dt.xctest.tool)下的授权状态机与静默 no-op。
/// 真实授权弹窗/投递行为无法在单测进程验证,不在此覆盖。
@MainActor
final class NotificationServiceTests: XCTestCase {
    func test_notificationStyleIdentifiersFollowDocumentedContract() {
        XCTAssertEqual(NotificationStyle.success.identifier, "ccspace.action.success")
        XCTAssertEqual(NotificationStyle.error.identifier, "ccspace.action.error")
        XCTAssertEqual(NotificationStyle.warning.identifier, "ccspace.action.warning")
        XCTAssertEqual(NotificationStyle.info.identifier, "ccspace.action.info")
        // 四类标识必须互不相同:同名会互相覆盖,混用会让通知中心堆积或吞通知。
        let identifiers = Set([
            NotificationStyle.success.identifier,
            NotificationStyle.error.identifier,
            NotificationStyle.warning.identifier,
            NotificationStyle.info.identifier
        ])
        XCTAssertEqual(identifiers.count, 4)
    }

    func test_notificationStyleSoundOnlyForErrorAndWarning() {
        XCTAssertNil(NotificationStyle.success.sound)
        XCTAssertNil(NotificationStyle.info.sound)
        XCTAssertNotNil(NotificationStyle.error.sound)
        XCTAssertNotNil(NotificationStyle.warning.sound)
    }

    func test_requestAuthorizationIfNeeded_inBundlelessTestProcessReturnsNotGrantedAndReplays() throws {
        try skipUnlessBundlelessTestProcess()
        let results = AuthorizationResultsBox()
        let service = NotificationService.shared

        // 首次调用:无 bundle 环境直接缓存终态 (false, nil),不触达系统。
        service.requestAuthorizationIfNeeded { granted, error in
            results.append(granted: granted, error: error)
        }
        // 幂等重放:第二次同样同步拿到未授权结果,不谎报 granted。
        service.requestAuthorizationIfNeeded { granted, error in
            results.append(granted: granted, error: error)
        }

        let values = results.all
        XCTAssertEqual(values.count, 2)
        for value in values {
            XCTAssertFalse(value.granted)
            XCTAssertNil(value.error)
        }
    }

    func test_sendAndNotify_inBundlelessTestProcessAreInert() throws {
        try skipUnlessBundlelessTestProcess()
        let service = NotificationService.shared

        // 无 bundle 环境下 send/notify 须在触达任何系统 API 前返回:不崩溃、不排队回调。
        service.send(title: "克隆完成", body: "demo repo", style: .success)
        service.send(title: "同步失败", body: "network down", style: .error)
        service.notify(actionName: "同步", feedback: CCSpaceFeedback(style: .error, message: "拉取失败"))
        service.notify(actionName: "同步", feedback: CCSpaceFeedback(style: .success, message: "已更新"))
        service.notify(actionName: "同步", feedback: nil)

        // send 未推进授权状态机:后续授权请求仍走同步重放路径,回调立即落地。
        let results = AuthorizationResultsBox()
        service.requestAuthorizationIfNeeded { granted, error in
            results.append(granted: granted, error: error)
        }
        let values = results.all
        XCTAssertEqual(values.count, 1)
        XCTAssertFalse(values[0].granted)
        XCTAssertNil(values[0].error)
    }

    /// 前置守卫:镜像 NotificationService.isRunningInAppBundle
    /// (Sources/CCSpace/Services/NotificationService.swift:39-42)的两个判定条件——
    /// bundle id 缺失(nil/空)或为 xctest 工具 id 时,服务内部会在触达
    /// UNUserNotificationCenter.current() 前返回 nil,测试进程安全。
    /// 若未来 runner 使 Bundle.main 携第三方 id,用例将真实触达授权状态机
    /// (无合法 bundle 下可 ObjC 异常崩进程),此时跳过而非冒崩。
    private func skipUnlessBundlelessTestProcess() throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let wouldTouchNotificationCenter =
            bundleID.isEmpty == false && bundleID != "com.apple.dt.xctest.tool"
        if wouldTouchNotificationCenter {
            throw XCTSkip(
                "当前测试进程携带非 xctest 的 bundle identifier(\(bundleID)),NotificationService 将真实触达 UNUserNotificationCenter,跳过用例"
            )
        }
    }
}

// MARK: - 夹具

/// 收集 @Sendable 授权回调结果:锁保护,可在任意线程追加。
private final class AuthorizationResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(granted: Bool, error: Error?)] = []

    func append(granted: Bool, error: Error?) {
        lock.lock()
        values.append((granted: granted, error: error))
        lock.unlock()
    }

    var all: [(granted: Bool, error: Error?)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
