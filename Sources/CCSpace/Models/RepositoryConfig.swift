import Foundation

struct RepositoryConfig: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var gitURL: String
    var repoName: String
    var createdAt: Date
    var updatedAt: Date
}
