import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var workplaceRootPath: String
    var preferredOpenActionID: String?
    var hasCompletedOnboarding: Bool = false

    enum CodingKeys: String, CodingKey {
        case workplaceRootPath
        case preferredOpenActionID = "preferredEditorID"
        case hasCompletedOnboarding
    }

    init(workplaceRootPath: String, preferredOpenActionID: String? = nil, hasCompletedOnboarding: Bool = false) {
        self.workplaceRootPath = workplaceRootPath
        self.preferredOpenActionID = preferredOpenActionID
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workplaceRootPath = try container.decode(String.self, forKey: .workplaceRootPath)
        preferredOpenActionID = try container.decodeIfPresent(String.self, forKey: .preferredOpenActionID)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }
}
