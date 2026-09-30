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
        // 设置页内部的页签不自称"设置":分段控件上 [设置][AI] 是自指,
        // 改为[通用][AI]与"根目录/仓库/引导"的内容范围一致。
        case .general: return "通用"
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
    /// `showingUnsavedChanges` 时追加「•」——段标签只能用字符表达未保存标记
    /// (在哪几个页签显示由 `SettingsTabPresentationState.pickerTitle(for:)` 收敛)。
    func pickerTitle(showingUnsavedChanges: Bool = false) -> String {
        let base = iconSystemName == nil ? title : "✦ \(title)"
        return showingUnsavedChanges ? "\(base) •" : base
    }
}

/// 设置页悬浮 tab 栏的展示状态(纯逻辑,便于测试)。
struct SettingsTabPresentationState {
    static let allTabs: [SettingsTab] = [.general, .ai]

    let selectedTab: SettingsTab
    /// AI 表单是否存在未保存修改(由 AISettingsSection 上报、RootSplitView 持有)。
    /// 通用页签没有表单输入,标记只落在 AI 页签上。
    let showsUnsavedChanges: Bool

    init(selectedTab: SettingsTab, showsUnsavedChanges: Bool = false) {
        self.selectedTab = selectedTab
        self.showsUnsavedChanges = showsUnsavedChanges
    }

    func isSelected(_ tab: SettingsTab) -> Bool {
        tab == selectedTab
    }

    func accessibilityLabel(for tab: SettingsTab) -> String {
        isSelected(tab) ? "\(tab.title)（当前页签）" : tab.title
    }

    /// 分段控件的段标题:未保存「•」标记只跟随 AI 页签,通用页签恒无。
    func pickerTitle(for tab: SettingsTab) -> String {
        tab.pickerTitle(showingUnsavedChanges: showsUnsavedChanges && tab == .ai)
    }
}

/// 设置页 AI 表单的展示状态(纯逻辑,便于测试):
/// 与已存配置逐字段比对得出"是否有未保存修改"(驱动保存按钮禁用与页签「•」标记),
/// 以及动作(测试连接/拉模型)的前置校验文案。
struct AISettingsFormPresentationState {
    let isDirty: Bool

    init(baseURL: String, modelName: String, apiKey: String, stored: AppSettings.AISettings?) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let stored else {
            // 从未配置过:三个输入全空即"无修改",任一非空即在新增配置。
            isDirty = trimmedBaseURL.isEmpty == false
                || trimmedModelName.isEmpty == false
                || trimmedAPIKey.isEmpty == false
            return
        }
        // 输入框回显的初值就来自 stored,按 trim 后比对——
        // 用户在输入框两端多敲了空格不算修改,保存时也会被 trim 掉。
        isDirty = trimmedBaseURL != stored.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedModelName != stored.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedAPIKey != stored.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 动作前置校验:返回 nil 表示通过,否则为要展示的错误文案。
    /// API Key 恒可选——Ollama/LM Studio 等本地服务不需要密钥,
    /// 缺 Key 由服务端 401 原样反馈,拦在门口反而配置不了本地服务。
    static func actionValidationError(
        baseURL: String,
        modelName: String,
        requireModel: Bool
    ) -> String? {
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先填写 Base URL"
        }
        if requireModel, modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先填写模型名"
        }
        return nil
    }
}
