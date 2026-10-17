import Foundation

struct SettingsUpdatePresentationState {
    let currentVersionDisplay: String
    let latestVersionDisplay: String?
    let showsUpdateAvailable: Bool
    /// 更新检查的状态提示文案(纯文本)。
    ///
    /// 渲染位置是工具栏 GitHub 按钮的悬浮提示与无障碍名称,不是设置页横幅:
    /// 更新检查每小时后台重试一次,私有仓库/离线环境下必然失败,
    /// 把它做成醒目横幅会把一个正常的后台噪声变成常驻报错。
    let statusHint: String?

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
            statusHint = lastErrorMessage
        } else if isChecking {
            statusHint = "正在检查更新…"
        } else {
            // 两种"无需提示"的形态:① 发现新版本——按钮文案与强调色已经说了;
            // ② 已是最新——按钮不高亮本身就是结论,再写一句"当前已是最新版本"
            //   只是把同一件事讲两遍。只有"正在检查"与"检查失败"值得留文案,
            //   因为它们需要被归因(私有仓库/离线环境下 404 是常态)。
            statusHint = nil
        }
    }
}

