import Foundation

struct RepositoryConfig: Equatable, Identifiable, Sendable, Codable {
    let id: UUID
    var gitURL: String
    var repoName: String
    var defaultBranch: String?
    var mrTargetBranches: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        gitURL: String,
        repoName: String,
        defaultBranch: String? = nil,
        mrTargetBranches: [String] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.gitURL = gitURL
        self.repoName = repoName
        self.defaultBranch = defaultBranch
        self.mrTargetBranches = mrTargetBranches
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        gitURL = try container.decode(String.self, forKey: .gitURL)
        repoName = try container.decode(String.self, forKey: .repoName)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        mrTargetBranches = try container.decodeIfPresent([String].self, forKey: .mrTargetBranches) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
