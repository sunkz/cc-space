import SwiftUI

/// 工具栏「获取更新」按钮的展示状态(纯值,便于单测)。
///
/// 按钮只显示 GitHub 标识,完整文案(含"发现新版本 vX.Y.Z")走悬浮提示与无障碍名称,
/// 所以这里产出的是**文案**与着色决策,而不是按钮标题。
struct UpdateButtonPresentationState: Equatable {
    /// 无障碍名称与悬浮文案。
    let title: String
    /// GitHub 标识是否用强调色。平时与版本号同为中性色,只有"发现新版本"时才用强调色
    /// 把入口凸显出来——否则 15pt 的实心标识会一直是最抢眼的东西。
    let usesAccentTint: Bool

    init(updatePresentationState: SettingsUpdatePresentationState) {
        if updatePresentationState.showsUpdateAvailable,
           let latestVersionDisplay = updatePresentationState.latestVersionDisplay {
            title = "获取更新：发现新版本 \(latestVersionDisplay)，点击前往 GitHub Releases 下载"
            usesAccentTint = true
        } else {
            title = "获取更新：前往 GitHub Releases 查看最新版本"
            usesAccentTint = false
        }
    }
}
