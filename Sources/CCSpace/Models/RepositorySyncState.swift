import Foundation

enum SyncStatus: String, Codable, Equatable, Sendable {
    case idle
    case cloning
    case pulling
    case switching
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
        case hasLocalDirectory
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
        // 按 String 解码再映射(与 AppSettings.appearanceMode 的既有做法一致):
        // 未来版本新增的 SyncStatus 直接 decode 枚举会抛错,导致整个
        // sync-states.json 被判为损坏重置为空;未知值回退 .idle 保证前向兼容。
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        let persistedStatus = rawStatus.flatMap(SyncStatus.init(rawValue:)) ?? .idle
        // 崩溃/强退时瞬态状态(.cloning/.pulling/.switching/.removing)会随防抖写盘留在 JSON 里,
        // 重启后没有任何流程会把它们改回终态,而批量拉取又会跳过这些状态——
        // 永久卡在"进行中"。解码时统一归位为 .idle,由磁盘刷新/用户操作重新驱动。
        switch persistedStatus {
        case .cloning, .pulling, .switching, .removing:
            status = .idle
        case .idle, .success, .failed:
            status = persistedStatus
        }
        localPath = try container.decode(String.self, forKey: .localPath)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        // 旧数据无此 key 时回退 false,由首次磁盘刷新修正(仅一次性)。
        hasLocalDirectory = try container.decodeIfPresent(Bool.self, forKey: .hasLocalDirectory) ?? false
    }
}
