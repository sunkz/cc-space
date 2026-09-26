import Foundation
import os
import UserNotifications

private let notificationLog = Logger(
    subsystem: "com.ccspace.app",
    category: "NotificationService"
)

/// 系统通知封装:在批量操作完成/失败时发送 macOS 通知。
///
/// 权限请求延迟到首次真正要发通知时才发起(进程内只请求一次)。此前在 App 启动时
/// 无条件请求,等于每次冷启动都弹一次系统授权框打扰用户;而已授权状态下重复请求
/// 不会再弹窗,因此延迟请求没有体验损失。
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    private var didRequestAuthorization = false
    /// 首次授权的真实结果,供后续幂等调用回放——不能谎报 granted=true,
    /// 否则被拒后的调用方会基于错误的授权假设行事。
    private var lastAuthorizationResult: (granted: Bool, error: Error?)?
    /// 授权进行中(didRequestAuthorization 已置位、系统回调未落地)抵达的
    /// 调用方回调:授权落地后统一回放。不收的话这些调用方既不弹授权框
    /// 也永远收不到回调,授权框挂着期间的所有通知会被静默吞掉。
    private var pendingAuthorizationCompletions: [@Sendable (Bool, Error?) -> Void] = []

    /// 安全获取 UNUserNotificationCenter。在无应用 bundle 的环境(如单元测试进程)中
    /// `current()` 会抛 ObjC 异常终止进程,因此先判断是否运行在应用 bundle 内。
    private var notificationCenter: UNUserNotificationCenter? {
        guard isRunningInAppBundle else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// 判断当前进程是否运行在合法的应用 bundle 内。
    /// XCTest 进程(如 com.apple.dt.xctest.tool)无合法 bundle identifier,跳过通知。
    private var isRunningInAppBundle: Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return bundleID.isEmpty == false && bundleID != "com.apple.dt.xctest.tool"
    }

    /// 请求通知授权(.alert / .sound / .badge)。幂等:进程内只请求一次,失败静默忽略。
    /// - Parameter completion: 授权结果回调,保证在主线程回调。首次调用时系统授权框
    ///   可能还挂着,调用方若要在授权后立即发通知,必须等这个回调,否则读到的状态是
    ///   `.notDetermined`,触发授权的那条通知会被丢弃。
    func requestAuthorizationIfNeeded(
        completion: (@Sendable (Bool, Error?) -> Void)? = nil
    ) {
        guard didRequestAuthorization == false else {
            if let lastAuthorizationResult {
                completion?(lastAuthorizationResult.granted, lastAuthorizationResult.error)
            } else {
                // 授权进行中:排队等系统回调落地后回放,不静默丢弃。
                if let completion {
                    pendingAuthorizationCompletions.append(completion)
                }
            }
            return
        }
        didRequestAuthorization = true
        guard let center = notificationCenter else {
            // 无 bundle 环境(测试进程/命令行)也要缓存终态:不写的话,
            // 后续每次 send 的 completion 都堆进 pendingAuthorizationCompletions
            // 且永远等不到系统回调,构成缓慢泄漏。
            lastAuthorizationResult = (false, nil)
            completion?(false, nil)
            return
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            // 授权失败不影响主流程,仅留痕。
            if let error {
                notificationLog.error("event=notification_authorization_failed reason=\(error.localizedDescription)")
            }
            // 回调保证在主线程:系统线程上收到的结果统一收拢进 MainActor 任务,
            // 与排队回放的调用方回调共用同一线程契约。
            Task { @MainActor in
                self?.lastAuthorizationResult = (granted, error)
                let pending = self?.pendingAuthorizationCompletions ?? []
                self?.pendingAuthorizationCompletions = []
                for pendingCompletion in pending {
                    pendingCompletion(granted, error)
                }
                completion?(granted, error)
            }
        }
    }

    /// 发送一条本地通知。
    /// - Parameters:
    ///   - title: 通知标题。
    ///   - body: 通知正文。
    ///   - style: 用于决定通知标识与是否发送(成功/失败/信息)。
    func send(title: String, body: String, style: NotificationStyle = .success) {
        guard notificationCenter != nil else { return }
        // 首次真正要发通知时才请求授权,不再在冷启动时打扰用户;
        // 发送判定放在授权回调之后,保证触发授权的那条通知不被丢弃。
        requestAuthorizationIfNeeded { _, _ in
            // UNUserNotificationCenter.current() 返回的是进程级单例,
            // 短暂强持有无生命周期风险。
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = style.sound

                let request = UNNotificationRequest(
                    identifier: style.identifier,
                    content: content,
                    trigger: nil
                )
                do {
                    try await center.add(request)
                } catch {
                    notificationLog.error("event=notification_delivery_failed reason=\(error.localizedDescription)")
                }
            }
        }
    }

    /// 便捷入口:根据操作名和反馈发送通知。
    func notify(actionName: String, feedback: CCSpaceFeedback?) {
        guard let feedback else { return }
        switch feedback.style {
        case .error:
            send(title: "\(actionName)失败", body: feedback.message, style: .error)
        case .success:
            send(title: "\(actionName)完成", body: feedback.message, style: .success)
        case .warning:
            send(title: "\(actionName)完成", body: feedback.message, style: .warning)
        case .info:
            send(title: "\(actionName)完成", body: feedback.message, style: .info)
        }
    }
}

enum NotificationStyle {
    case success
    case error
    case warning
    case info

    /// 通知标识。同名标识会覆盖上一条同类通知,避免通知中心堆积。
    var identifier: String {
        switch self {
        case .success: return "ccspace.action.success"
        case .error: return "ccspace.action.error"
        case .warning: return "ccspace.action.warning"
        case .info: return "ccspace.action.info"
        }
    }

    var sound: UNNotificationSound? {
        switch self {
        case .error, .warning: return .default
        default: return nil
        }
    }
}
