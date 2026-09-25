import XCTest
@testable import CCSpace

final class AICommitPromptBuilderTests: XCTestCase {
    private func makeEntry(
        filePath: String,
        insertions: Int = 3,
        deletions: Int = 1,
        patch: String = "@@ -1,2 +1,3 @@\n+a"
    ) -> GitDiffEntry {
        GitDiffEntry(
            filePath: filePath,
            insertions: insertions,
            deletions: deletions,
            patch: patch
        )
    }

    func test_systemPromptRequiresSingleLineSubjectWithoutExplanation() {
        let prompt = AICommitPromptBuilder.systemPrompt()

        XCTAssertTrue(prompt.contains("只输出主题行本身"))
        XCTAssertTrue(prompt.contains("不超过 72 个字符"))
    }

    func test_userPromptIncludesStyleSubjectsAndDiffSections() {
        let prompt = AICommitPromptBuilder.userPrompt(
            diffs: [makeEntry(filePath: "Sources/Foo.swift")],
            recentCommitSubjects: ["feat: 添加功能", "fix: 修复问题"]
        )

        XCTAssertTrue(prompt.contains("## 最近提交主题"))
        XCTAssertTrue(prompt.contains("- feat: 添加功能"))
        XCTAssertTrue(prompt.contains("### Sources/Foo.swift"))
        XCTAssertTrue(prompt.contains("```diff"))
        XCTAssertTrue(prompt.contains("+a"))
    }

    func test_userPromptOmitsStyleSectionWhenNoRecentSubjects() {
        let prompt = AICommitPromptBuilder.userPrompt(
            diffs: [makeEntry(filePath: "Sources/Foo.swift")],
            recentCommitSubjects: []
        )

        XCTAssertFalse(prompt.contains("## 最近提交主题"))
        XCTAssertTrue(prompt.contains("## 本次未提交改动"))
    }

    func test_oversizedFilePatchIsTruncatedWithMarker() {
        let longPatch = String(repeating: "+line\n", count: 2000)
        let sections = AICommitPromptBuilder.makeDiffSections(
            diffs: [makeEntry(filePath: "Sources/Big.swift", patch: longPatch)]
        )

        XCTAssertTrue(sections.contains("该文件内容过长，已截断"))
        XCTAssertLessThanOrEqual(sections.count, AICommitPromptBuilder.maxFilePatchCharacters + 200)
    }

    func test_overBudgetDegradesLargestFileToStatsOnly() {
        // 8 个文件的 patch 各 6000 字符(单文件上限内),总量超 40000 预算才触发降级。
        // Large 改动量最大,应最先被降级为仅统计;其余文件内容保留。
        let largePatch = String(repeating: "+a\n", count: 2000)
        let smallPatch = String(repeating: "+b\n", count: 2000)
        var diffs = [
            makeEntry(filePath: "Sources/Large.swift", insertions: 9_999, patch: largePatch)
        ]
        diffs.append(contentsOf: (1...7).map { index in
            makeEntry(filePath: "Sources/Small\(index).swift", insertions: 100, patch: smallPatch)
        })

        let sections = AICommitPromptBuilder.makeDiffSections(diffs: diffs)

        XCTAssertTrue(sections.contains("### Sources/Large.swift"))
        XCTAssertFalse(sections.contains("+a"), "最大改动文件的内容应被降级省略")
        XCTAssertTrue(sections.contains("+b"), "较小文件的内容应保留")
        XCTAssertLessThanOrEqual(sections.count, AICommitPromptBuilder.maxTotalPatchCharacters + 200)
    }

    func test_binaryFileRenderedAsStatsOnly() {
        let sections = AICommitPromptBuilder.makeDiffSections(
            diffs: [makeEntry(filePath: "Assets/icon.png", insertions: -1, deletions: -1, patch: "")]
        )

        XCTAssertTrue(sections.contains("（二进制文件）"))
        XCTAssertTrue(sections.contains("内容已省略"))
        XCTAssertFalse(sections.contains("```diff"))
    }
}
