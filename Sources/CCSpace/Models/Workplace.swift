import Foundation

struct Workplace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var selectedRepositoryIDs: [UUID]
    var branch: String? = nil
    var createdAt: Date
    var updatedAt: Date

    var hasLocalDirectory: Bool {
        FileSystemService().directoryExists(at: path)
    }
}
