import XCTest
@testable import CCSpace

final class DiffSplitRowBuilderTests: XCTestCase {
    private func line(
        _ kind: DiffPatchLine.Kind,
        _ text: String,
        old: Int? = nil,
        new: Int? = nil
    ) -> DiffPatchLine {
        DiffPatchLine(kind: kind, text: text, oldLineNumber: old, newLineNumber: new)
    }

    private func pairOf(_ row: DiffSplitRow) -> (left: DiffPatchLine?, right: DiffPatchLine?) {
        guard case .pair(let left, let right) = row.content else {
            XCTFail("应为配对行,实际:\(row.content)")
            return (nil, nil)
        }
        return (left, right)
    }

    func test_pairsChangeBlockAndFillsShorterSide() {
        let rows = DiffSplitRowBuilder.rows(from: [
            line(.hunkHeader(context: nil), "@@ -1,3 +1,3 @@"),
            line(.removed, "-a", old: 1),
            line(.removed, "-b", old: 2),
            line(.added, "+c", new: 1),
            line(.context, " d", old: 3, new: 2)
        ])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].content, .hunkHeader(line(.hunkHeader(context: nil), "@@ -1,3 +1,3 @@")))
        // 两条删除对一条新增:第一行 (a,c),第二行 (b,·)。
        XCTAssertEqual(pairOf(rows[1]).left?.text, "-a")
        XCTAssertEqual(pairOf(rows[1]).right?.text, "+c")
        XCTAssertEqual(pairOf(rows[2]).left?.text, "-b")
        XCTAssertNil(pairOf(rows[2]).right)
        // 上下文行两侧相同,行号分别来自旧/新侧。
        let contextPair = pairOf(rows[3])
        XCTAssertEqual(contextPair.left, contextPair.right)
        XCTAssertEqual(contextPair.left?.oldLineNumber, 3)
        XCTAssertEqual(contextPair.right?.newLineNumber, 2)
    }

    func test_onlyAddedLeavesLeftSideEmpty() {
        let rows = DiffSplitRowBuilder.rows(from: [
            line(.context, " x", old: 1, new: 1),
            line(.added, "+y", new: 2),
            line(.added, "+z", new: 3)
        ])
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(pairOf(rows[1]).left)
        XCTAssertEqual(pairOf(rows[1]).right?.text, "+y")
        XCTAssertNil(pairOf(rows[2]).left)
        XCTAssertEqual(pairOf(rows[2]).right?.text, "+z")
    }

    func test_trailingChangeBlockIsFlushed() {
        // 变更块位于末尾(后续无上下文行)也要输出。
        let rows = DiffSplitRowBuilder.rows(from: [
            line(.removed, "-tail", old: 9)
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(pairOf(rows[0]).left?.text, "-tail")
        XCTAssertNil(pairOf(rows[0]).right)
    }

    func test_noteSpansRowAndSplitsPendingBlock() {
        let rows = DiffSplitRowBuilder.rows(from: [
            line(.added, "+a", new: 1),
            line(.note, "\\ No newline at end of file")
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].content, .note(line(.note, "\\ No newline at end of file")))
        XCTAssertEqual(pairOf(rows[0]).right?.text, "+a")
    }
}
