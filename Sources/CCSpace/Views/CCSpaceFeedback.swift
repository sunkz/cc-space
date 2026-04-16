import SwiftUI

enum CCSpaceFeedbackStyle: Equatable {
    case success
    case info
    case warning
    case error

    var systemImage: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .success:
            return .green
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var backgroundColor: Color {
        switch self {
        case .success:
            return Color.green.opacity(0.07)
        case .info:
            return Color.primary.opacity(0.02)
        case .warning:
            return Color.orange.opacity(0.08)
        case .error:
            return Color.red.opacity(0.05)
        }
    }
}

struct CCSpaceFeedback: Equatable {
    let style: CCSpaceFeedbackStyle
    let message: String

    var systemImage: String {
        style.systemImage
    }
}

struct CCSpaceFeedbackBanner: View {
    let feedback: CCSpaceFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.systemImage)
            .font(.callout)
            .foregroundStyle(feedback.style.foregroundColor)
            .ccspaceInsetPanel(background: feedback.style.backgroundColor)
    }
}

enum CCSpaceFeedbackFactory {
    static func actionSuccess(_ message: String) -> CCSpaceFeedback {
        CCSpaceFeedback(
            style: .success,
            message: message
        )
    }

    static func actionError(action: String, error: Error) -> CCSpaceFeedback {
        CCSpaceFeedback(
            style: .error,
            message: "\(action)失败：\(error.localizedDescription)"
        )
    }

    static func repositoryActionResult(
        repositoryName: String,
        syncState: RepositorySyncState?,
        successMessage: String,
        fallbackFailureMessage: String
    ) -> CCSpaceFeedback {
        guard let syncState else {
            return CCSpaceFeedback(style: .error, message: fallbackFailureMessage)
        }
        if syncState.status == .success {
            return actionSuccess(successMessage)
        }
        return CCSpaceFeedback(
            style: .error,
            message: "\(fallbackFailureMessage)：\(syncState.lastError ?? "未知错误")"
        )
    }

    static func bulkSyncSummary(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int = 0
    ) -> CCSpaceFeedback {
        if failedCount > 0 && successCount > 0 {
            return CCSpaceFeedback(
                style: .warning,
                message: bulkSyncMessage(
                    successCount: successCount,
                    failedCount: failedCount,
                    skippedCount: skippedCount
                )
            )
        }
        if failedCount > 0 {
            return CCSpaceFeedback(
                style: .error,
                message: skippedCount > 0
                    ? "同步失败，\(failedCount) 个失败，\(skippedCount) 个跳过"
                    : "同步失败，\(failedCount) 个仓库失败"
            )
        }
        if successCount > 0 && skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "已同步 \(successCount) 个仓库，跳过 \(skippedCount) 个"
            )
        }
        if skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "没有需要同步的默认分支仓库，已跳过 \(skippedCount) 个"
            )
        }
        if successCount == 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "没有可同步的仓库"
            )
        }
        return actionSuccess("已同步 \(successCount) 个仓库")
    }

    private static func bulkSyncMessage(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int
    ) -> String {
        if skippedCount > 0 {
            return "同步完成，\(successCount) 个成功，\(failedCount) 个失败，\(skippedCount) 个跳过"
        }
        return "同步完成，\(successCount) 个成功，\(failedCount) 个失败"
    }
}
