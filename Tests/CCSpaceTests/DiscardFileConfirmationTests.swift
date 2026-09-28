import XCTest
@testable import CCSpace

final class DiscardFileConfirmationTests: XCTestCase {
    func test_addedFileMessageDescribesDeletion() {
        let message = DiscardFileConfirmation.message(for: entry(.added))
        XCTAssertTrue(message.contains("删除新文件"))
        XCTAssertTrue(message.contains("不可恢复"))
    }

    func test_deletedFileMessageDescribesRestore() {
        let message = DiscardFileConfirmation.message(for: entry(.deleted))
        XCTAssertTrue(message.contains("恢复被删除的"))
    }

    func test_modifiedFileMessageDescribesDiscardToHead() {
        let message = DiscardFileConfirmation.message(for: entry(.modified))
        XCTAssertTrue(message.contains("丢弃"))
        XCTAssertTrue(message.contains("恢复到上次提交"))
        XCTAssertTrue(message.contains("不可恢复"))
    }

    func test_renamedFileUsesDiscardMessage() {
        let message = DiscardFileConfirmation.message(for: entry(.renamed))
        XCTAssertTrue(message.contains("丢弃"))
    }

    func test_titleContainsFileName() {
        let entry = GitDiffEntry(
            filePath: "Sources/App/main.swift",
            insertions: 1,
            deletions: 1,
            patch: "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b"
        )
        XCTAssertTrue(DiscardFileConfirmation.title(for: entry).contains("main.swift"))
    }

    /// GitDiffEntry 的变更类型由 patch 头部派生,用最小 patch 构造指定类型。
    private func entry(_ changeType: GitDiffChangeType) -> GitDiffEntry {
        let patch: String
        switch changeType {
        case .added:
            patch = "diff --git a/x b/x\nnew file mode 100644\n@@ -0,0 +1 @@\n+hi"
        case .deleted:
            patch = "diff --git a/x b/x\ndeleted file mode 100644\n@@ -1 +0,0 @@\n-hi"
        case .renamed:
            patch = "diff --git a/x b/y\nrename from x\nrename to y"
        case .modified:
            patch = "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b"
        }
        return GitDiffEntry(filePath: "src/x.swift", insertions: 1, deletions: 1, patch: patch)
    }
}
