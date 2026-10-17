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
        // 按 String 解码再映射:未来版本新增的 SyncStatus 直接 decode 枚举会抛错,
        // 整个 sync-states.json 被判损坏重置;未知值回退 .idle 保证前向兼容。
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        let persistedStatus = rawStatus.flatMap(SyncStatus.init(rawValue:)) ?? .idle
        // 瞬态(.cloning/.pulling/.switching/.removing)只由本进程活跃操作写入,崩溃时随防抖写盘
        // 留在 JSON 里且无人归位、批量拉取又会跳过 → 解码时统一复位 .idle。
        switch persistedStatus {
        case .cloning, .pulling, .switching, .removing:
            status = .idle
        case .idle, .success, .failed:
            status = persistedStatus
        }
        localPath = try container.decode(String.self, forKey: .localPath)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        // 旧数据无此 key 时回退 false,由启动的磁盘校正/磁盘刷新修正。
        hasLocalDirectory = try container.decodeIfPresent(Bool.self, forKey: .hasLocalDirectory) ?? false
    }
}

extension RepositorySyncState {
    /// 回写比对口径:只有 status/lastError/lastSyncedAt/hasLocalDirectory 属于操作结果;
    /// 工作区标识与 localPath 是身份/位置字段,不参与回写比对。
    static func hasOwnChanges(from original: RepositorySyncState, to updated: RepositorySyncState) -> Bool {
        updated.status != original.status
            || updated.lastError != original.lastError
            || updated.lastSyncedAt != original.lastSyncedAt
            || updated.hasLocalDirectory != original.hasLocalDirectory
    }

    /// 字段级增量合并:只写 updated 相对 original 实际变化的字段,无变化返回 nil;整行覆盖会把数分钟回写窗口内的
    /// 最新写入改回旧值(lost update)。premarkedTransient 只归位本操作自己预标的瞬态,他人转轮不得强改。
    static func merging(
        updated: RepositorySyncState,
        onto original: RepositorySyncState,
        in latest: RepositorySyncState,
        premarkedTransient: SyncStatus?
    ) -> RepositorySyncState? {
        let changesStatus = updated.status != original.status
        let changesError = updated.lastError != original.lastError
        let changesSyncedAt = updated.lastSyncedAt != original.lastSyncedAt
        let changesHasLocalDirectory = updated.hasLocalDirectory != original.hasLocalDirectory
        let hasOwnChanges = Self.hasOwnChanges(from: original, to: updated)
        let convergesTransient: Bool
        if let premarkedTransient {
            convergesTransient = latest.status == premarkedTransient && latest.status != updated.status
        } else {
            convergesTransient = false
        }
        guard hasOwnChanges || convergesTransient else { return nil }
        var merged = latest
        if changesStatus || convergesTransient { merged.status = updated.status }
        if changesError { merged.lastError = updated.lastError }
        if changesSyncedAt { merged.lastSyncedAt = updated.lastSyncedAt }
        if changesHasLocalDirectory { merged.hasLocalDirectory = updated.hasLocalDirectory }
        guard merged != latest else { return nil }
        return merged
    }
}
