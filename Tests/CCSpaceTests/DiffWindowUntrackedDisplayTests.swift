import XCTest
@testable import CCSpace

final class DiffWindowUntrackedDisplayTests: XCTestCase {
    /// 未跟踪文件由 `git diff --no-index` 生成,patch 头带 `new file mode` → 归类为新增。
    private func addedEntry(_ name: String) -> GitDiffEntry {
        GitDiffEntry(
            filePath: name,
            insertions: 1,
            deletions: 0,
            patch: "diff --git a/\(name) b/\(name)\nnew file mode 100644\n@@ -0,0 +1 @@\n+x\n"
        )
    }

    private func modifiedEntry(_ name: String) -> GitDiffEntry {
        GitDiffEntry(filePath: name, insertions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-x\n+y\n")
    }

    func test_noNoticeBelowUntrackedLimit() {
        let entries = (0..<DiffWindowUntrackedDisplay.limit).map { addedEntry("f\($0).txt") }
        XCTAssertNil(DiffWindowUntrackedDisplay.truncationNotice(for: Array(entries.dropLast())))
        XCTAssertNil(DiffWindowUntrackedDisplay.truncationNotice(for: []))
    }

    func test_noticeAtOrAboveUntrackedLimit() {
        let entries = (0..<DiffWindowUntrackedDisplay.limit).map { addedEntry("f\($0).txt") }
        XCTAssertNotNil(DiffWindowUntrackedDisplay.truncationNotice(for: entries))
        XCTAssertNotNil(DiffWindowUntrackedDisplay.truncationNotice(for: entries + [addedEntry("extra.txt")]))
    }

    func test_onlyAddedEntriesCountTowardLimit() {
        // 大量已跟踪文件的改动不应误报"未跟踪文件被截断"。
        let entries = (0..<(DiffWindowUntrackedDisplay.limit + 50)).map { modifiedEntry("f\($0).txt") }
        XCTAssertNil(DiffWindowUntrackedDisplay.truncationNotice(for: entries))
    }

    func test_noticeKeepsDisplayScopeAndCommitScopeApart() {
        let entries = (0..<DiffWindowUntrackedDisplay.limit).map { addedEntry("f\($0).txt") }
        guard let notice = DiffWindowUntrackedDisplay.truncationNotice(for: entries) else {
            return XCTFail("达到上限应有提示文案")
        }
        XCTAssertEqual(notice, "未跟踪文件较多，列表最多展示前 100 个新增文件；提交仍会包含全部改动")
    }
}
