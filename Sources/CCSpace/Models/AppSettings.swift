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
}
