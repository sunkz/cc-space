import Foundation

struct Workplace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var selectedRepositoryIDs: [UUID]
    var branch: String?
    var isPinned: Bool
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case selectedRepositoryIDs
        case branch
        case isPinned
        case isArchived
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        name: String,
        path: String,
        selectedRepositoryIDs: [UUID],
        branch: String? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.selectedRepositoryIDs = selectedRepositoryIDs
        self.branch = branch
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        selectedRepositoryIDs = try container.decode([UUID].self, forKey: .selectedRepositoryIDs)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(selectedRepositoryIDs, forKey: .selectedRepositoryIDs)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var hasLocalDirectory: Bool {
        FileSystemService().directoryExists(at: path)
    }
}
