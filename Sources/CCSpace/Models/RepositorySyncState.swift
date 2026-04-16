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

    var hasLocalDirectory: Bool {
        FileSystemService().directoryExists(at: localPath)
    }
}
