import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    /// 外观模式;system 表示跟随系统设置。
    enum AppearanceMode: String, Codable, Sendable {
        case system
        case light
        case dark
    }

    /// AI 服务配置:OpenAI 兼容服务(提交信息生成/测试连接/模型列表)。
    ///
    /// API Key 的持久化归属由 `apiKeyManagedExternally` 声明:
    /// - true(正常态):密钥活在系统钥匙串,settings.json **不再包含** apiKey 字段,
    ///   明文不再随备份/iCloud/`.corrupt-*` 副本外泄;
    /// - false(降级态):钥匙串写入失败时的兼容路径,密钥仍按旧格式明文落盘,
    ///   SettingsStore 会在后续成功写入钥匙串后把它收敛掉。
    /// 解码时按"文件里有没有 apiKey 字段"自动判定,不额外持久化布尔。
    struct AISettings: Codable, Equatable, Sendable {
        /// 服务根地址,如 https://open.bigmodel.cn/api/paas/v4。
        var baseURL: String
        /// 模型名,如 glm-5.3-flash。
        var modelName: String
        /// 服务 API Key。
        var apiKey: String = ""
        /// true 表示密钥由钥匙串托管,编码时跳过 apiKey 字段。
        var apiKeyManagedExternally: Bool = false

        enum CodingKeys: String, CodingKey {
            case baseURL
            case modelName
            case apiKey
        }

        init(
            baseURL: String,
            modelName: String,
            apiKey: String = "",
            apiKeyManagedExternally: Bool = false
        ) {
            self.baseURL = baseURL
            self.modelName = modelName
            self.apiKey = apiKey
            self.apiKeyManagedExternally = apiKeyManagedExternally
        }

        /// 手写解码并全部走 decodeIfPresent:Swift 属性默认值不参与合成解码,
        /// 缺 key 即抛错会把整个 settings.json 判为损坏而整体重置;
        /// 新增字段的默认值在此处兜底,保证旧数据前向兼容。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            let persistedKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            apiKey = persistedKey ?? ""
            // 文件里没有 apiKey 字段 = 钥匙串托管态。
            apiKeyManagedExternally = persistedKey == nil
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseURL, forKey: .baseURL)
            try container.encode(modelName, forKey: .modelName)
            if apiKeyManagedExternally == false {
                try container.encode(apiKey, forKey: .apiKey)
            }
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
        // 与其它字段一致走 decodeIfPresent + 默认值:缺 key 即抛错会把整个 settings.json
        // 判为损坏而整体重置;空串表示未配置,与 AppSettings(workplaceRootPath: "") 对齐。
        workplaceRootPath = try container.decodeIfPresent(String.self, forKey: .workplaceRootPath) ?? ""
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

extension AppSettings {
    /// 托管态密钥回填:AI 配置存在、密钥由钥匙串托管且内存副本为空时,从钥匙串读回,
    /// 保证消费方(AI 服务/设置页)按"完整配置"读取。非托管态或内存已持有明文时不动作。
    /// App 启动的 settingsReader(CCSpace.swift)与 SettingsStore 的启动迁移共用此规则。
    mutating func backfillAPIKeyFromKeychainIfManaged(using keychain: any APIKeySecretStore) {
        guard var ai = aiSettings, ai.apiKeyManagedExternally, ai.apiKey.isEmpty else { return }
        ai.apiKey = keychain.readAPIKey() ?? ""
        aiSettings = ai
    }
}
