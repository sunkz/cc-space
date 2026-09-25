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

        // 无分隔符、字段数不符(2 个分隔符)的行被跳过,只保留合法条目。
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "valid")
        XCTAssertEqual(entries[0].index, 2)
    }

    func test_parseListHandlesEmptyOutput() {
        XCTAssertTrue(GitStashEntry.parseList("").isEmpty)
    }
}
