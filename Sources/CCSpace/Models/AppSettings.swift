import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    /// 外观模式;system 表示跟随系统设置。
    enum AppearanceMode: String, Codable, Sendable {
        case system
        case light
        case dark
    }

    var workplaceRootPath: String
    var preferredOpenActionID: String?
    var hasCompletedOnboarding: Bool = false
    var lastSelectedRoute: String?
    var lastSelectedWorkplaceID: String?
    var appearanceMode: AppearanceMode = .system

    enum CodingKeys: String, CodingKey {
        case workplaceRootPath
        case preferredOpenActionID = "preferredEditorID"
        case hasCompletedOnboarding
        case lastSelectedRoute
        case lastSelectedWorkplaceID
        case appearanceMode
    }

    init(
        workplaceRootPath: String,
        preferredOpenActionID: String? = nil,
        hasCompletedOnboarding: Bool = false,
        appearanceMode: AppearanceMode = .system
    ) {
        self.workplaceRootPath = workplaceRootPath
        self.preferredOpenActionID = preferredOpenActionID
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.appearanceMode = appearanceMode
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
    }
}

