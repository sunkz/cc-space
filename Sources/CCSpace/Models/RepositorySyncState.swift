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

extension RepositorySyncState {
    /// 操作方在行快照上可能改动的展示字段口径:status/lastError/lastSyncedAt/hasLocalDirectory。
    /// 工作区标识、localPath 等身份/位置字段不属于操作结果,不参与回写比对。
    static func hasOwnChanges(from original: RepositorySyncState, to updated: RepositorySyncState) -> Bool {
        updated.status != original.status
            || updated.lastError != original.lastError
            || updated.lastSyncedAt != original.lastSyncedAt
            || updated.hasLocalDirectory != original.hasLocalDirectory
    }

    /// 字段级增量合并回写:只把 updated 相对 original 实际改动的字段写入 latest,
    /// 其余字段保留 latest 的最新值;无任何可写变化时返回 nil(不落库)。
    ///
    /// 后台操作(批量 pull/push、切分支等)从取快照到回写可间隔数分钟,期间磁盘刷新、
    /// 其他操作的收口可能已改写行上与本操作无关的字段;整行覆盖回写会把窗口内的
    /// 最新写入改回操作前旧值(lost update)。比对口径见 `hasOwnChanges(from:to:)`。
    ///
    /// - Parameters:
    ///   - updated: 操作结果(基于 original 派生)。
    ///   - original: 操作开始前的行快照。
    ///   - latest: 回写时刻 Store 里的最新行。
    ///   - premarkedTransient: 本操作自己预标的瞬态(如 .pulling/.switching)。
    ///     操作结果与快照恰好同值时也必须把该瞬态归位成结果终态,否则行永久卡在转轮;
    ///     只收口**本操作自己预标过**的瞬态,他人转轮属于另一轮操作,不得强改。
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
