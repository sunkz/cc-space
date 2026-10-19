import Foundation

/// 工作区分支快照的跨切换缓存。
///
/// 详情页带 `.id(workplace.id)`,每次切换整棵子树连同 `@State branchSnapshots` 一起销毁,重建即对每个
/// 本地仓库重起 2 个 git 进程(21 仓实测 ~380ms wall),且这段时间列表先渲染成"无分支信息"再回填。
/// 来回切同一批工作区是常态操作,代价按点击次数线性增长,所以在 Store 之下留一层进程内缓存。
///
/// 只有"够新 + 键覆盖完整"才复用(判据在调用方),过期数据由详情页的 30s 轮询与动作后的 seed 失效兜底。
@MainActor
final class WorkplaceBranchSnapshotCache {
    struct Entry {
        let loadedAt: Date
        let snapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot]
    }

    /// 上限按"一屏能来回切的工作区数"取,不是按工作区总数:分支名单可以有上千条,不设上限就是无界增长。
    static let maxWorkplaceEntryCount = 16

    private var entries: [UUID: Entry] = [:]
    /// 最近使用顺序,末位最新;只在 record / 命中判定时维护,纯读不改动。
    private var accessOrder: [UUID] = []

    func snapshots(for workplaceID: UUID) -> [RepositoryBranchCacheKey: RepositoryBranchSnapshot] {
        return entries[workplaceID]?.snapshots ?? [:]
    }

    /// 挂载首轮能否跳过 git 扫描:`maxAge` 内写入过,且当前每个本地仓库键都已有一条快照。
    /// 键覆盖必须逐条核对——工作区在缓存写入后新增过仓库时,只判年龄会让新仓库一直空着。
    func canReuse(
        for workplaceID: UUID,
        maxAge: TimeInterval,
        covering keys: [RepositoryBranchCacheKey],
        now: Date = Date()
    ) -> Bool {
        guard let entry = entries[workplaceID],
              now.timeIntervalSince(entry.loadedAt) < maxAge,
              keys.isEmpty == false else {
            return false
        }
        let reusable = keys.allSatisfy { entry.snapshots[$0] != nil }
        if reusable { touch(workplaceID) }
        return reusable
    }

    func record(
        _ snapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot],
        for workplaceID: UUID,
        now: Date = Date()
    ) {
        entries[workplaceID] = Entry(loadedAt: now, snapshots: snapshots)
        touch(workplaceID)
        while entries.count > Self.maxWorkplaceEntryCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func invalidate(_ workplaceID: UUID) {
        entries.removeValue(forKey: workplaceID)
        accessOrder.removeAll { $0 == workplaceID }
    }

    var entryCount: Int { entries.count }

    private func touch(_ workplaceID: UUID) {
        accessOrder.removeAll { $0 == workplaceID }
        accessOrder.append(workplaceID)
    }
}
