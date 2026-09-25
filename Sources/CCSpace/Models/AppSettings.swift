import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    /// 外观模式;system 表示跟随系统设置。
    enum AppearanceMode: String, Codable, Sendable {
        case system
        case light
        case dark
    }

    /// AI 生成提交信息使用的 OpenAI 兼容服务配置。
    struct AISettings: Codable, Equatable, Sendable {
        /// 服务根地址,如 https://open.bigmodel.cn/api/paas/v4。
        var baseURL: String
        /// 模型名,如 glm-5.3-flash。
        var modelName: String
        /// 服务 API Key。
        var apiKey: String = ""

        enum CodingKeys: String, CodingKey {
            case baseURL
            case modelName
            case apiKey
        }

        init(
            baseURL: String,
            modelName: String,
            apiKey: String = ""
        ) {
            self.baseURL = baseURL
            self.modelName = modelName
            self.apiKey = apiKey
        }

        /// 手写解码并全部走 decodeIfPresent:Swift 属性默认值不参与合成解码,
        /// 缺 key 即抛错会把整个 settings.json 判为损坏而整体重置;
        /// 新增字段的默认值在此处兜底,保证旧数据前向兼容。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        }
    }

    var workplaceRootPath: String
    var preferredOpenActionID: String?
    var hasCompletedOnboarding: Bool = false
    var lastSelectedRoute: String?
    var lastSelectedWorkplaceID: String?
    var appearanceMode: AppearanceMode = .system
    /// AI 服务配置;nil 表示未启用。
    var aiSettings: AISettings?

    enum CodingKeys: String, CodingKey {
        case workplaceRootPath
        case preferredOpenActionID = "preferredEditorID"
        case hasCompletedOnboarding
        case lastSelectedRoute
        case lastSelectedWorkplaceID
        case appearanceMode
        case aiSettings
    }

    init(
        workplaceRootPath: String,
        preferredOpenActionID: String? = nil,
        hasCompletedOnboarding: Bool = false,
        appearanceMode: AppearanceMode = .system,
        aiSettings: AISettings? = nil
    ) {
        self.workplaceRootPath = workplaceRootPath
        self.preferredOpenActionID = preferredOpenActionID
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.appearanceMode = appearanceMode
        self.aiSettings = aiSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workplaceRootPath = try container.decode(String.self, forKey: .workplaceRootPath)
        preferredOpenActionID = try container.decodeIfPresent(String.self, forKey: .preferredOpenActionID)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        lastSelectedRoute = try container.decodeIfPresent(String.self, forKey: .lastSelectedRoute)
        lastSelectedWorkplaceID = try container.decodeIfPresent(String.self, forKey: .lastSelectedWorkplaceID)
        // 按 String 解码再映射,未知值(如未来版本新增的模式)回退到 system,
        // 避免 decode 抛错导致整个 settings.json 被重置。
        let rawAppearanceMode = try container.decodeIfPresent(String.self, forKey: .appearanceMode)
        appearanceMode = rawAppearanceMode.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        aiSettings = try container.decodeIfPresent(AISettings.self, forKey: .aiSettings)
    }
}
