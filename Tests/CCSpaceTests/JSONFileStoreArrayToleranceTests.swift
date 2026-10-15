import XCTest
@testable import CCSpace

/// `JSONFileStore.loadArrayToleratingBadElements` 的回归锁。
///
/// 这是数组类持久化文件(repositories.json / sync-states.json / workplaces.json)
/// 的解码入口:**单个元素**坏了不能把整个文件判为损坏——否则一行脏数据会让
/// 用户整库仓库配置被重置(此前该路径完全没有测试覆盖,整文件级容错测试
/// 挡不住元素级的回归)。
final class JSONFileStoreArrayToleranceTests: XCTestCase {
    private func makeStore() throws -> (store: JSONFileStore, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ccspace-array-tolerance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (JSONFileStore(rootDirectory: root), root)
    }

    private func write(_ data: Data, file: String, root: URL) throws {
        try data.write(to: root.appendingPathComponent(file))
    }

    /// 好元素全部留下,坏元素计数,原文件不被覆写。
    func test_keepsGoodElementsAndReportsDroppedCount() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // 第二条缺 `gitURL`(RepositoryConfig 的必填字段)→ 该元素解码失败。
        let json = """
        [
          {"id":"11111111-1111-1111-1111-111111111111","gitURL":"git@github.com:org/a.git","repoName":"a","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
          {"id":"22222222-2222-2222-2222-222222222222","repoName":"b","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
          {"id":"33333333-3333-3333-3333-333333333333","gitURL":"git@github.com:org/c.git","repoName":"c","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        ]
        """
        try write(Data(json.utf8), file: "repositories.json", root: root)

        let result = try XCTUnwrap(
            store.loadArrayToleratingBadElements(RepositoryConfig.self, from: "repositories.json"),
            "元素级容错入口不得把整个文件判为不可用"
        )

        XCTAssertEqual(result.values.count, 2, "两条好记录必须全部解出")
        XCTAssertEqual(
            Set(result.values.map(\.repoName)),
            ["a", "c"]
        )
        XCTAssertEqual(result.droppedCount, 1, "坏元素必须被计数,不能静默丢弃")
    }

    /// 全部元素都坏:返回空数组 + droppedCount,而不是 nil(区别于"文件不存在/整体不是数组")。
    func test_returnsEmptyWithDroppedCountWhenEveryElementIsBad() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(#"[{"nope":1},{"nope":2}]"#.utf8), file: "repositories.json", root: root)

        let result = try XCTUnwrap(
            store.loadArrayToleratingBadElements(RepositoryConfig.self, from: "repositories.json")
        )
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertEqual(result.droppedCount, 2)
    }

    /// 文件不存在 / 整体不是数组 / 非法 JSON → nil,让调用方走"缺省值或整文件损坏"路径。
    ///
    /// 这个区分很关键:把"文件根本读不出来"当成"数组里全坏了"返回空数组,
    /// 调用方会以为配置是空的并覆写文件,原内容彻底没了。
    func test_returnsNilWhenFileMissingOrNotAnArray() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(
            store.loadArrayToleratingBadElements(RepositoryConfig.self, from: "repositories.json"),
            "文件不存在必须返回 nil"
        )

        try write(Data(#"{"not":"an array"}"#.utf8), file: "repositories.json", root: root)
        XCTAssertNil(
            store.loadArrayToleratingBadElements(RepositoryConfig.self, from: "repositories.json"),
            "顶层不是数组必须返回 nil"
        )

        try write(Data("not-a-json".utf8), file: "repositories.json", root: root)
        XCTAssertNil(
            store.loadArrayToleratingBadElements(RepositoryConfig.self, from: "repositories.json"),
            "非法 JSON 必须返回 nil"
        )
    }
}
