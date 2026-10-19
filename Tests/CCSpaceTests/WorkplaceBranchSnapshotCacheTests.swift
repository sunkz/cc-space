import XCTest
@testable import CCSpace

@MainActor
final class WorkplaceBranchSnapshotCacheTests: XCTestCase {
    private func key(_ workplace: UUID, _ repository: Int) -> RepositoryBranchCacheKey {
        RepositoryBranchCacheKey(workplaceID: workplace, repositoryID: UUID(uuidString: repoID(repository))!)
    }

    private func repoID(_ index: Int) -> String {
        String(format: "20000000-0000-0000-0000-%012d", index)
    }

    private func snapshot(_ repository: Int) -> RepositoryBranchSnapshot {
        RepositoryBranchSnapshot(currentBranch: "main-\(repository)", branches: ["main-\(repository)"], status: nil)
    }

    func test_recordsAndReturnsSnapshotsPerWorkplace() {
        let cache = WorkplaceBranchSnapshotCache()
        let workplace = UUID()
        let other = UUID()
        cache.record([key(workplace, 1): snapshot(1)], for: workplace)
        cache.record([:], for: other)

        XCTAssertEqual(cache.snapshots(for: workplace).count, 1)
        XCTAssertTrue(cache.snapshots(for: other).isEmpty)
        XCTAssertTrue(cache.snapshots(for: UUID()).isEmpty)
    }

    func test_canReuseRequiresAgeAndFullKeyCoverage() {
        let cache = WorkplaceBranchSnapshotCache()
        let workplace = UUID()
        let keys = [key(workplace, 1), key(workplace, 2)]
        cache.record(
            [keys[0]: snapshot(1), keys[1]: snapshot(2)],
            for: workplace,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(
            cache.canReuse(
                for: workplace,
                maxAge: 5,
                covering: keys,
                now: Date(timeIntervalSince1970: 1_003)
            )
        )
        // 超龄:必须重扫,不能因为"键都在"就一直复用。
        XCTAssertFalse(
            cache.canReuse(
                for: workplace,
                maxAge: 5,
                covering: keys,
                now: Date(timeIntervalSince1970: 1_006)
            )
        )
        // 缓存写入后工作区又纳入了新仓库:键覆盖不完整,复用会让那一行永远空着。
        XCTAssertFalse(
            cache.canReuse(
                for: workplace,
                maxAge: 5,
                covering: keys + [key(workplace, 3)],
                now: Date(timeIntervalSince1970: 1_001)
            )
        )
        // 没有本地仓库时不走复用:这条判据对空键集合恒真,会让"零仓库"永远不刷新。
        XCTAssertFalse(
            cache.canReuse(
                for: workplace,
                maxAge: 5,
                covering: [],
                now: Date(timeIntervalSince1970: 1_001)
            )
        )
        XCTAssertFalse(cache.canReuse(for: UUID(), maxAge: 5, covering: keys, now: Date()))
    }

    func test_evictsLeastRecentlyUsedBeyondCapacity() {
        let cache = WorkplaceBranchSnapshotCache()
        let capacity = WorkplaceBranchSnapshotCache.maxWorkplaceEntryCount
        let workplaces = (0...capacity).map { _ in UUID() }
        for workplace in workplaces {
            cache.record([key(workplace, 1): snapshot(1)], for: workplace)
        }
        XCTAssertEqual(cache.entryCount, capacity)
        // 未再触碰的最早一条已被挤掉,末位仍在。
        XCTAssertTrue(cache.snapshots(for: workplaces[0]).isEmpty)
        XCTAssertEqual(cache.snapshots(for: workplaces[capacity]).count, 1)

        // 复用判定命中会把它顶到最近使用,后续写入不应先淘汰它。
        let protected = workplaces[1]
        XCTAssertTrue(
            cache.canReuse(for: protected, maxAge: 60, covering: [key(protected, 1)], now: Date())
        )
        cache.record([key(UUID(), 1): snapshot(1)], for: UUID())
        XCTAssertEqual(cache.snapshots(for: protected).count, 1)
    }

    func test_invalidateDropsEntryAndUsageOrder() {
        let cache = WorkplaceBranchSnapshotCache()
        let workplace = UUID()
        cache.record([key(workplace, 1): snapshot(1)], for: workplace)
        cache.invalidate(workplace)

        XCTAssertTrue(cache.snapshots(for: workplace).isEmpty)
        XCTAssertEqual(cache.entryCount, 0)
    }
}
