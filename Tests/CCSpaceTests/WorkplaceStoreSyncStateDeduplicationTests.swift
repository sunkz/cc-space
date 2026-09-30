import XCTest
@testable import CCSpace

/// P0 回归锁:sync-states.json 出现重复组合键(workplaceID-repositoryID)时,
/// 加载必须去重,且启动必经的 `reconcileHasLocalDirectoryFlags` 不得因重复键
/// 走 `Dictionary(uniqueKeysWithValues:)` precondition 失败直接 trap。
@MainActor
final class WorkplaceStoreSyncStateDeduplicationTests: XCTestCase {
    func test_deduplicatedSyncStatesKeepsFirstOccurrence() {
        let workplaceID = UUID()
        let repositoryID = UUID()
        let first = RepositorySyncState(
            workplaceID: workplaceID,
            repositoryID: repositoryID,
            status: .success,
            localPath: "/tmp/first",
            hasLocalDirectory: true
        )
        var duplicate = first
        duplicate.localPath = "/tmp/second"
        duplicate.status = .failed

        let deduped = WorkplaceStore.deduplicatedSyncStates([first, duplicate, first])

        XCTAssertEqual(deduped, [first], "重复组合键只保留首个,与磁盘刷新去重语义一致")
    }

    func test_loadDeduplicatesSyncStatesSharingCompositeKey() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingPath = root.appendingPathComponent("missing-repo").path
        // 两行同组合键但内容不同:解码本身不报错(容错解码/手工编辑都可能引入),
        // 旧实现会把两行都载入内存。
        try duplicatedSyncStatesJSON(localPath: missingPath).write(
            to: root.appendingPathComponent("sync-states.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkplaceStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.syncStates.count, 1, "重复组合键必须在加载时去重(保留首个)")
        XCTAssertEqual(store.syncStates.first?.localPath, missingPath)
        XCTAssertTrue(store.syncStates.first?.hasLocalDirectory ?? false)
    }

    /// 启动 `.task` 每次无条件调用该方法:重复键若进建字典会 precondition trap(崩溃循环)。
    func test_reconcileHasLocalDirectoryFlagsToleratesDuplicatedCompositeKey() async throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingPath = root.appendingPathComponent("missing-repo").path
        try duplicatedSyncStatesJSON(localPath: missingPath).write(
            to: root.appendingPathComponent("sync-states.json"),
            atomically: true,
            encoding: .utf8
        )
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = WorkplaceStore(fileStore: fileStore)

        await store.reconcileHasLocalDirectoryFlags()

        XCTAssertEqual(store.syncStates.count, 1)
        // 去重后保留的首行声明 hasLocalDirectory=true,而目录并不存在 → 应被校正为 false。
        XCTAssertEqual(store.syncStates.first?.hasLocalDirectory, false)

        store.flushSyncStates()
        let reloaded = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.syncStates.count, 1, "去重结果随落盘收敛,不复活重复行")
    }

    private func duplicatedSyncStatesJSON(localPath: String) -> String {
        """
        [
          {
            "workplaceID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "repositoryID": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "status": "success",
            "localPath": "\(localPath)",
            "hasLocalDirectory": true
          },
          {
            "workplaceID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "repositoryID": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "status": "failed",
            "localPath": "\(localPath)",
            "hasLocalDirectory": false
          }
        ]
        """
    }
}
