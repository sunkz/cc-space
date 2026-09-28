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

/// 设置页底部悬浮 tab 的页签。
enum SettingsTab: Hashable {
    /// 通用设置:根目录、仓库列表、新手引导。
    case general
    /// AI 配置:服务地址、模型、API Key。
    case ai

    var title: String {
        switch self {
        case .general: return "设置"
        case .ai: return "AI"
        }
    }

    /// 页签文字前的系统图标名:nil 表示纯文字。仅 AI 页签带 sparkles 标识。
    var iconSystemName: String? {
        switch self {
        case .general: return nil
        case .ai: return "sparkles"
        }
    }

    /// 原生分段控件(NSSegmentedControl)的段标题:段标签渲染不了 SF Symbols,
    /// 有图标的页签用 Unicode 星号「✦」前缀替代。
    var pickerTitle: String {
        iconSystemName == nil ? title : "✦ \(title)"
    }
}

/// 设置页悬浮 tab 栏的展示状态(纯逻辑,便于测试)。
struct SettingsTabPresentationState {
    static let allTabs: [SettingsTab] = [.general, .ai]

    let selectedTab: SettingsTab

    func isSelected(_ tab: SettingsTab) -> Bool {
        tab == selectedTab
    }

    func accessibilityLabel(for tab: SettingsTab) -> String {
        isSelected(tab) ? "\(tab.title)（当前页签）" : tab.title
    }
}

/// 设置页「Git 状态检测」区块的展示状态,由检测原始结果推导。
struct GitEnvironmentPresentationState {
    /// git 环境状态:检测中 / 可用 / 不可用。
    enum Availability: Equatable {
        case checking
        case available
        case unavailable
    }

    let availability: Availability
    /// `git --version` 输出;检测中或无结果时为 nil。
    let versionDisplay: String?
    /// 探测到的 git 可执行文件路径;检测中或未找到时为 nil。
    let executablePathDisplay: String?

    init(info: GitEnvironmentInfo?, isChecking: Bool) {
        if isChecking {
            availability = .checking
        } else if let info, info.isAvailable {
            availability = .available
        } else {
            availability = .unavailable
        }

        let trimmedVersion = info?.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        versionDisplay = trimmedVersion?.isEmpty == false ? trimmedVersion : nil

        let trimmedPath = info?.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        executablePathDisplay = trimmedPath?.isEmpty == false ? trimmedPath : nil
    }

    /// 从 `git --version` 输出提取的简短版本号(如 "2.39.5");无法解析时为 nil。
    var shortVersionDisplay: String? {
        // 输出形如 "git version 2.39.5 (Apple Git-150)",第三个词是版本号。
        guard let versionDisplay else { return nil }
        let tokens = versionDisplay.components(separatedBy: .whitespaces)
        guard tokens.count >= 3, tokens[0] == "git", tokens[1] == "version" else {
            return nil
        }
        let candidate = tokens[2]
        let isVersionNumber = candidate.isEmpty == false
            && candidate.allSatisfy { $0.isNumber || $0 == "." }
        return isVersionNumber ? candidate : nil
    }

    /// 工具栏紧凑文案:可用时为 "git <版本号>",不可用时为 "git 不可用";检测中为 nil(仅图标)。
    var compactLabel: String? {
        switch availability {
        case .checking:
            return nil
        case .available:
            if let shortVersionDisplay {
                return "git \(shortVersionDisplay)"
            }
            return "git 可用"
        case .unavailable:
            return "git 不可用"
        }
    }

    /// 悬停提示文案,含完整版本、可执行文件路径与操作说明。
    var quickHelpText: String {
        switch availability {
        case .checking:
            return "正在检测 git 环境…"
        case .available:
            var lines = ["git 可用"]
            if let versionDisplay {
                lines.append("版本：\(versionDisplay)")
            }
            if let executablePathDisplay {
                lines.append("路径：\(executablePathDisplay)")
            }
            lines.append("点击重新检测")
            return lines.joined(separator: "\n")
        case .unavailable:
            var lines = ["未检测到可用的 git，可安装 Xcode Command Line Tools 后重新检测"]
            if let executablePathDisplay {
                lines.append("路径：\(executablePathDisplay)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
