import Foundation

struct SettingsUpdatePresentationState {
    let currentVersionDisplay: String
    let latestVersionDisplay: String?
    let showsUpdateAvailable: Bool
    let statusFeedback: CCSpaceFeedback?

    init(
        currentVersion: String,
        latestVersion: String?,
        isChecking: Bool,
        lastErrorMessage: String?
    ) {
        let trimmedCurrentVersion = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLatestVersion = latestVersion?.trimmingCharacters(in: .whitespacesAndNewlines)

        currentVersionDisplay = "v\(trimmedCurrentVersion.isEmpty ? "0" : trimmedCurrentVersion)"

        if let trimmedLatestVersion, trimmedLatestVersion.isEmpty == false {
            latestVersionDisplay = "v\(trimmedLatestVersion)"
            showsUpdateAvailable = UpdateChecker.isNewerVersion(
                trimmedLatestVersion,
                than: trimmedCurrentVersion
            )
        } else {
            latestVersionDisplay = nil
            showsUpdateAvailable = false
        }

        if let lastErrorMessage, lastErrorMessage.isEmpty == false {
            statusFeedback = CCSpaceFeedback(style: .error, message: lastErrorMessage)
        } else if isChecking {
            statusFeedback = CCSpaceFeedback(style: .info, message: "正在检查更新…")
        } else if showsUpdateAvailable, let latestVersionDisplay {
            statusFeedback = CCSpaceFeedback(
                style: .warning,
                message: "发现新版本 \(latestVersionDisplay)，可前往 Releases 下载。"
            )
        } else if let latestVersionDisplay {
            statusFeedback = CCSpaceFeedback(
                style: .success,
                message: "当前已是最新版本 \(latestVersionDisplay)。"
            )
        } else {
            statusFeedback = nil
        }
    }
}
