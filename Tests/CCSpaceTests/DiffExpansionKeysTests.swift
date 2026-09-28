import XCTest
@testable import CCSpace

final class DiffExpansionKeysTests: XCTestCase {
    private func entry(_ filePath: String, patch: String) -> GitDiffEntry {
        GitDiffEntry(filePath: filePath, insertions: 1, deletions: 0, patch: patch)
    }

    func test_keysSurvivePatchContentChanges() {
        // 磁盘内容一变 diff.id(掺了 patch 散列)就换,折叠状态若按 id 键控会全部重新展开。
        let before = [entry("a.txt", patch: "@@ -1 +1 @@\n-x\n"), entry("b.txt", patch: "@@ -1 +1 @@\n-y\n")]
        let after = [entry("a.txt", patch: "@@ -1 +1 @@\n-new\n"), entry("b.txt", patch: "@@ -1 +1 @@\n-y\n")]
        XCTAssertNotEqual(before[0].id, after[0].id)
        XCTAssertEqual(DiffExpansionKeys.make(for: before), DiffExpansionKeys.make(for: after))
    }

    func test_keysFollowListOrderAndRepeatedPathsGetOccurrenceSuffix() {
        let diffs = [
            entry("same.txt", patch: "p1"),
            entry("same.txt", patch: "p2"),
            entry("other.txt", patch: "p3"),
        ]
        XCTAssertEqual(
            DiffExpansionKeys.make(for: diffs),
            ["same.txt", "same.txt#1", "other.txt"]
        )
    }

    func test_emptyDiffListProducesNoKeys() {
        XCTAssertEqual(DiffExpansionKeys.make(for: []), [])
    }
}
