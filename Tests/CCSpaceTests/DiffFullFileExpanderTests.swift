import XCTest
@testable import CCSpace

final class DiffFullFileExpanderTests: XCTestCase {
    /// 两个 hunk:第一个净增 1 行(old 1..3 → new 1..4),第二个改一行(old 8..10 → new 9..11)。
    private let samplePatch = """
    diff --git a/src/file.swift b/src/file.swift
    index 1111111..2222222 100644
    --- a/src/file.swift
    +++ b/src/file.swift
    @@ -1,3 +1,4 @@
     ctxA
    -removed1
    +added1
    +added2
     ctxB
    @@ -8,3 +9,3 @@
     ctx10
    -removed10
    +added10
     ctx11
    """

    /// 新文件全文(11 行),hunk 之间有 4 行未被 patch 覆盖(g1..g4)。
    private let sampleFileContent = """
    ctxA
    added1
    added2
    ctxB
    g1
    g2
    g3
    g4
    ctx10
    added10
    ctx11
    """

    func test_fillsGapsBetweenHunksWithIndependentLineNumbers() {
        let patchLines = DiffPatchLineParser.parse(samplePatch)
        let expanded = DiffFullFileExpander.expand(patchLines: patchLines, fileContent: sampleFileContent)

        // 头2 + body(5+4) + gap 4 = 15 行。
        XCTAssertEqual(expanded.count, 15)

        // hunk1 之后净增 1 行,gap 行(g1..g4)的旧侧行号(4..7)与新侧(5..8)错开;
        // 旧实现把 oldLineNumber 写成与 newLineNumber 相等,会在此漂移。
        let gapLines = expanded.filter { $0.kind == .context && $0.text.hasPrefix(" g") }
        XCTAssertEqual(gapLines.map(\.text), [" g1", " g2", " g3", " g4"])
        XCTAssertEqual(gapLines.map(\.oldLineNumber), [4, 5, 6, 7])
        XCTAssertEqual(gapLines.map(\.newLineNumber), [5, 6, 7, 8])

        // 两个 hunk 头原样保留。
        XCTAssertEqual(expanded.filter { $0.kind.isHunkHeader }.count, 2)
    }

    func test_appendsLeadingAndTrailingLinesOutsideHunks() {
        let patchLines = DiffPatchLineParser.parse("@@ -2,1 +2,1 @@\n b\n")
        let expanded = DiffFullFileExpander.expand(patchLines: patchLines, fileContent: "a\nb\nc\n")

        XCTAssertEqual(expanded.count, 4)
        XCTAssertEqual(expanded[0].text, " a")
        XCTAssertEqual(expanded[0].oldLineNumber, 1)
        XCTAssertEqual(expanded[0].newLineNumber, 1)
        XCTAssertEqual(expanded[1].kind.isHunkHeader, true)
        XCTAssertEqual(expanded[2].text, " b")
        XCTAssertEqual(expanded[3].text, " c")
        XCTAssertEqual(expanded[3].oldLineNumber, 3)
        XCTAssertEqual(expanded[3].newLineNumber, 3)
    }


    func test_handlesCRLFAndTrailingNewlineWithoutSpuriousEmptyLines() {
        // CRLF 行尾不应按 \r 再切出空行;末尾换行不应多出一个空行。
        let patchLines = DiffPatchLineParser.parse("@@ -3,1 +3,1 @@\n l3\n")
        let expanded = DiffFullFileExpander.expand(patchLines: patchLines, fileContent: "l1\r\nl2\r\nl3\r\nl4\r\n")

        XCTAssertEqual(expanded.count, 5)
        XCTAssertEqual(expanded.map(\.text), [" l1", " l2", "@@ -3,1 +3,1 @@", " l3", " l4"])
        XCTAssertFalse(expanded.contains { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func test_returnsPatchLinesWhenFileContentIsNil() {
        let patchLines = DiffPatchLineParser.parse(samplePatch)
        XCTAssertEqual(DiffFullFileExpander.expand(patchLines: patchLines, fileContent: nil), patchLines)
    }

    func test_returnsPatchLinesWhenPatchHasNoHunks() {
        // 空改动、纯重命名/权限变化的 patch 没有 hunk,不展开(避免把整个文件当上下文铺开)。
        XCTAssertEqual(
            DiffFullFileExpander.expand(patchLines: DiffPatchLineParser.parse(""), fileContent: sampleFileContent),
            []
        )
    }

    func test_workingTreeFileContentReadsExistingFile() throws {
        let directory = NSTemporaryDirectory() + "DiffFullFileExpanderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "a\nb\nc\n".write(toFile: directory + "/f.txt", atomically: true, encoding: .utf8)

        XCTAssertEqual(
            DiffFullFileExpander.workingTreeFileContent(localPath: directory, filePath: "f.txt"),
            "a\nb\nc\n"
        )
    }

    func test_workingTreeFileContentReturnsNilWhenFileDoesNotExist() {
        XCTAssertNil(
            DiffFullFileExpander.workingTreeFileContent(
                localPath: NSTemporaryDirectory(),
                filePath: "no-such-file-\(UUID().uuidString)"
            )
        )
    }
}

extension DiffPatchLine.Kind {
    /// hunk 头判定;展开结果中头行应原样保留在原位置。
    var isHunkHeader: Bool {
        if case .hunkHeader = self { return true }
        return false
    }
}
