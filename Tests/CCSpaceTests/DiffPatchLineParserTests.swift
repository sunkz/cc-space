import XCTest
@testable import CCSpace

final class DiffPatchLineParserTests: XCTestCase {
    private let samplePatch = """
    diff --git a/src/main.swift b/src/main.swift
    index 1111111..2222222 100644
    --- a/src/main.swift
    +++ b/src/main.swift
    @@ -1,4 +1,4 @@ func hello()
     line1
    -old line
    +new line
     keep
    @@ -10,2 +10,3 @@
     x
    +y
     z
    \\ No newline at end of file
    """

    func test_skipsMetadataLines() {
        let lines = DiffPatchLineParser.parse(samplePatch)
        // `diff --git` / `index` / `---` / `+++` 四行元数据被跳过。
        XCTAssertEqual(lines.count, 10)
        XCTAssertFalse(lines.contains { $0.text.hasPrefix("diff --git") || $0.text.hasPrefix("index ") })
        XCTAssertFalse(lines.contains { $0.text.hasPrefix("--- ") || $0.text.hasPrefix("+++ ") })
    }

    func test_parsesHunkHeaderWithContext() {
        let lines = DiffPatchLineParser.parse(samplePatch)
        guard case .hunkHeader(let context) = lines[0].kind else {
            return XCTFail("首行应为 hunk 头,实际:\(lines[0])")
        }
        XCTAssertEqual(context, "func hello()")
        XCTAssertNil(lines[0].oldLineNumber)
        XCTAssertNil(lines[0].newLineNumber)
    }

    func test_tracksLineNumbersAcrossKinds() {
        let lines = DiffPatchLineParser.parse(samplePatch)
        // hunk @@ -1,4 +1,4 @@ 之后:context(1,1) → removed(2,·) → added(·,2) → context(3,3)。
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].oldLineNumber, 1)
        XCTAssertEqual(lines[1].newLineNumber, 1)
        XCTAssertEqual(lines[2].kind, .removed)
        XCTAssertEqual(lines[2].oldLineNumber, 2)
        XCTAssertNil(lines[2].newLineNumber)
        XCTAssertEqual(lines[3].kind, .added)
        XCTAssertEqual(lines[3].newLineNumber, 2)
        XCTAssertNil(lines[3].oldLineNumber)
        XCTAssertEqual(lines[4].kind, .context)
        XCTAssertEqual(lines[4].oldLineNumber, 3)
        XCTAssertEqual(lines[4].newLineNumber, 3)
    }

    func test_resetsCountersOnSecondHunk() {
        let lines = DiffPatchLineParser.parse(samplePatch)
        // 第二个 hunk @@ -10,2 +10,3 @@(无上下文),行号从 10 重新计数。
        guard case .hunkHeader(let context) = lines[5].kind else {
            return XCTFail("应解析出第二个 hunk 头,实际:\(lines[5])")
        }
        XCTAssertNil(context)
        XCTAssertEqual(lines[6].oldLineNumber, 10)
        XCTAssertEqual(lines[6].newLineNumber, 10)
        XCTAssertEqual(lines[7].newLineNumber, 11)
        XCTAssertEqual(lines[8].oldLineNumber, 11)
        XCTAssertEqual(lines[8].newLineNumber, 12)
    }

    func test_parsesNoNewlineNote() {
        let lines = DiffPatchLineParser.parse(samplePatch)
        XCTAssertEqual(lines.last?.kind, .note)
        XCTAssertEqual(lines.last?.text, "\\ No newline at end of file")
        XCTAssertNil(lines.last?.oldLineNumber)
        XCTAssertNil(lines.last?.newLineNumber)
    }

    func test_emptyPatchProducesNoLines() {
        XCTAssertEqual(DiffPatchLineParser.parse(""), [])
    }
}
