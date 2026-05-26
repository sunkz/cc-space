import Foundation

enum SyncStatus: String, Codable, Equatable, Sendable {
    case idle
    case cloning
    case pulling
    case success
    case failed
    case removing
}

struct RepositorySyncState: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(workplaceID.uuidString)-\(repositoryID.uuidString)" }
    let workplaceID: UUID
    let repositoryID: UUID
    var status: SyncStatus
    var localPath: String
    var lastError: String?
    var lastSyncedAt: Date?
    var hasLocalDirectory: Bool

    private enum CodingKeys: String, CodingKey {
        case workplaceID, repositoryID, status, localPath, lastError, lastSyncedAt
    }

    init(
        workplaceID: UUID,
        repositoryID: UUID,
        status: SyncStatus,
        localPath: String,
        lastError: String? = nil,
        lastSyncedAt: Date? = nil,
        hasLocalDirectory: Bool = false
    ) {
        self.workplaceID = workplaceID
        self.repositoryID = repositoryID
        self.status = status
        self.localPath = localPath
        self.lastError = lastError
        self.lastSyncedAt = lastSyncedAt
        self.hasLocalDirectory = hasLocalDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workplaceID = try container.decode(UUID.self, forKey: .workplaceID)
        repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
        status = try container.decode(SyncStatus.self, forKey: .status)
        localPath = try container.decode(String.self, forKey: .localPath)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        hasLocalDirectory = FileManager.default.fileExists(atPath: localPath)
    }
}
