import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var workplaceRootPath: String
    var preferredOpenActionID: String?

    enum CodingKeys: String, CodingKey {
        case workplaceRootPath
        case preferredOpenActionID = "preferredEditorID"
    }
}
