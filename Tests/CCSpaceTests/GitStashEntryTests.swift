import XCTest
@testable import CCSpace

final class GitStashEntryTests: XCTestCase {
    func test_parseListParsesMessagesDatesAndIndices() {
        let output = """
        CCSpace manual stash\u{1F}2026-08-20T10:30:00+08:00
        CCSpace temporary worktree safety stash\u{1F}2026-08-19T18:00:00+08:00
        """

        let entries = GitStashEntry.parseList(output)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].message, "CCSpace manual stash")
        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].message, "CCSpace temporary worktree safety stash")
        // 日期可解析(非 distantPast 兜底)且顺序正确。
        XCTAssertNotEqual(entries[0].date, .distantPast)
        XCTAssertNotEqual(entries[1].date, .distantPast)
        XCTAssertLessThan(entries[1].date, entries[0].date)
        XCTAssertEqual(entries[0].ref, "stash@{0}")
        XCTAssertEqual(entries[1].ref, "stash@{1}")
        XCTAssertEqual(entries[0].id, 0)
    }

    func test_parseListSkipsEmptyAndMalformedLines() {
        // 行序即栈位置:被跳过的行同样占位,后续条目的 index 不回缩。
        let output = """
        only-one-field
        CCSpace manual stash\u{1F}not-a-date\u{1F}extra
        valid\u{1F}2026-08-20T10:30:00+08:00
        """

        let entries = GitStashEntry.parseList(output)

        // 仅「无任何分隔符」的行被跳过(仍占位,index 不回缩)。含分隔符的行不再因
        // 字段数不符被丢弃:消息本身可能含 \u{1F},此前丢行会让其后所有条目的
        // index 前移,pop/drop 按 index 操作会命中错误的 stash。日期解析失败时
        // 兜底 .distantPast。
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 1)
        XCTAssertEqual(entries[0].message, "CCSpace manual stash\u{1F}not-a-date")
        XCTAssertEqual(entries[0].date, .distantPast)
        XCTAssertEqual(entries[1].index, 2)
        XCTAssertEqual(entries[1].message, "valid")
        XCTAssertNotEqual(entries[1].date, .distantPast)
    }

    func test_parseListHandlesEmptyOutput() {
        XCTAssertTrue(GitStashEntry.parseList("").isEmpty)
    }

    /// 新格式 `%gs\u{1F}%cI\u{1F}%H`:破坏性操作按对象 ID 对账的前提是解析侧拿到它。
    func test_parseListReadsObjectIDFromThirdField() {
        let objectID = String(repeating: "a", count: 40)
        let output = """
        WIP on main: 提交标题\u{1F}2026-08-20T10:30:00+08:00\u{1F}\(objectID)
        """

        let entries = GitStashEntry.parseList(output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "WIP on main: 提交标题")
        XCTAssertEqual(entries[0].objectID, objectID)
        XCTAssertNotEqual(entries[0].date, .distantPast)
    }

    /// 消息本身含分隔符时,尾部两个字段仍按「日期 + 对象 ID」取,消息段完整重建。
    func test_parseListKeepsSeparatorBearingMessageAndReadsObjectID() {
        let objectID = String(repeating: "b", count: 40)
        let output = "第一段\u{1F}第二段\u{1F}2026-08-20T10:30:00+08:00\u{1F}\(objectID)"

        let entries = GitStashEntry.parseList(output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "第一段\u{1F}第二段")
        XCTAssertEqual(entries[0].objectID, objectID)
        XCTAssertNotEqual(entries[0].date, .distantPast)
    }

    /// 老的两字段输出(不含 %H)必须解析成 objectID == nil,
    /// 否则对账会把"没核验过"当成"核验通过"。
    func test_parseListWithoutObjectIDFieldYieldsNil() {
        let entries = GitStashEntry.parseList("WIP on main: x\u{1F}2026-08-20T10:30:00+08:00")

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].objectID)
        XCTAssertNotEqual(entries[0].date, .distantPast)
    }

    /// 末段不是 40 位十六进制就不是对象 ID:防止把"消息含分隔符的老行"的最后一段
    /// 误当成 SHA,把日期解析成 objectID。
    func test_parseListRejectsNonHexThirdFieldAsObjectID() {
        let entries = GitStashEntry.parseList("消息\u{1F}备注\u{1F}2026-08-20T10:30:00+08:00")

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].objectID)
        XCTAssertEqual(entries[0].message, "消息\u{1F}备注")
        XCTAssertNotEqual(entries[0].date, .distantPast)
    }
}
