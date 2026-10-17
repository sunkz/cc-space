import Foundation

struct AppSettings: Codable, Equatable, Sendable {
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

    init(workplaceRootPath: String) {
        self.workplaceRootPath = workplaceRootPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 必须 decodeIfPresent + 默认值:缺 key 即抛错会把整个 settings.json 判为损坏并重置为空。
        workplaceRootPath = try container.decodeIfPresent(String.self, forKey: .workplaceRootPath) ?? ""
        preferredOpenActionID = try container.decodeIfPresent(String.self, forKey: .preferredOpenActionID)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        lastSelectedRoute = try container.decodeIfPresent(String.self, forKey: .lastSelectedRoute)
        lastSelectedWorkplaceID = try container.decodeIfPresent(String.self, forKey: .lastSelectedWorkplaceID)
        // 按 String 解码再映射:未来版本新增的模式回退 system,避免 decode 抛错重置整个 settings.json。
        let rawAppearanceMode = try container.decodeIfPresent(String.self, forKey: .appearanceMode)
        appearanceMode = rawAppearanceMode.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}

