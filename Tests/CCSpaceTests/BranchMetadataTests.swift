import XCTest
@testable import CCSpace

final class GitBranchMetadataTests: XCTestCase {
    func test_parseForEachRefReadsNameDateAndTrack() {
        // 行为 git for-each-ref %01 分隔的真实输出:名/时间戳/track/upstream 引用。
        let line = "feature/a\u{01}1789000000\u{01}[ahead 1, behind 2]\u{01}refs/remotes/origin/feature/a"
        let metadata = GitBranchMetadata.parseForEachRef(line)

        XCTAssertEqual(Set(metadata.keys), ["feature/a"])
        XCTAssertEqual(metadata["feature/a"]?.aheadCount, 1)
        XCTAssertEqual(metadata["feature/a"]?.behindCount, 2)
        XCTAssertEqual(metadata["feature/a"]?.upstreamGone, false)
        XCTAssertEqual(metadata["feature/a"]?.hasUpstream, true)
        XCTAssertEqual(metadata["feature/a"]?.lastCommitDate, Date(timeIntervalSince1970: 1_789_000_000))
    }

    func test_parseForEachRefHandlesMultipleLinesAndEmptyTrack() {
        let output = """
        main\u{01}1789000100\u{01}\u{01}refs/remotes/origin/main
        release/1.2\u{01}1789000200\u{01}[behind 5]\u{01}refs/remotes/origin/release/1.2
        local-only\u{01}1789000300\u{01}\u{01}
        """
        let metadata = GitBranchMetadata.parseForEachRef(output)

        XCTAssertEqual(Set(metadata.keys), ["main", "release/1.2", "local-only"])
        // 有上游且同步:track 为空但 upstream 非空 → hasUpstream true。
        XCTAssertEqual(metadata["main"]?.hasUpstream, true)
        XCTAssertEqual(metadata["main"]?.behindCount, 0)
        XCTAssertEqual(metadata["release/1.2"]?.behindCount, 5)
        // 无上游:upstream 字段为空。
        XCTAssertEqual(metadata["local-only"]?.hasUpstream, false)
    }

    func test_parseForEachRefIgnoresMalformedLines() {
        let metadata = GitBranchMetadata.parseForEachRef("broken-line\n\u{01}123\u{01}\u{01}")
        XCTAssertTrue(metadata.isEmpty)
    }

    func test_parseUpstreamTrackVariants() {
        func assertTrack(
            _ raw: String,
            ahead: Int,
            behind: Int,
            gone: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let parsed = GitBranchMetadata.parseUpstreamTrack(raw)
            XCTAssertEqual(parsed.ahead, ahead, file: file, line: line)
            XCTAssertEqual(parsed.behind, behind, file: file, line: line)
            XCTAssertEqual(parsed.gone, gone, file: file, line: line)
        }

        assertTrack("[ahead 3]", ahead: 3, behind: 0, gone: false)
        assertTrack("[behind 2]", ahead: 0, behind: 2, gone: false)
        assertTrack("[gone]", ahead: 0, behind: 0, gone: true)
        assertTrack("", ahead: 0, behind: 0, gone: false)
        assertTrack("  ", ahead: 0, behind: 0, gone: false)
    }
}

final class GitRefDivergenceTests: XCTestCase {
    func test_parseReadsLeftRightCounts() {
        let divergence = GitRefDivergence.parse("3\t5\n")
        XCTAssertEqual(divergence?.baseOnlyCount, 3)
        XCTAssertEqual(divergence?.headOnlyCount, 5)
    }

    func test_parseAcceptsSpaceSeparator() {
        let divergence = GitRefDivergence.parse("0 1")
        XCTAssertEqual(divergence?.baseOnlyCount, 0)
        XCTAssertEqual(divergence?.headOnlyCount, 1)
    }

    func test_parseRejectsMalformedOutput() {
        XCTAssertNil(GitRefDivergence.parse("only-one-field"))
        XCTAssertNil(GitRefDivergence.parse(""))
        XCTAssertNil(GitRefDivergence.parse("a\tb"))
    }
}

final class BranchActivityOrderTests: XCTestCase {
    private func metadata(_ timestamp: TimeInterval?) -> GitBranchMetadata {
        GitBranchMetadata(
            lastCommitDate: timestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func test_sortsByRecentCommitDateDescending() {
        let metadata: [String: GitBranchMetadata] = [
            "old": metadata(100),
            "new": metadata(300),
            "middle": metadata(200),
        ]

        let sorted = BranchActivityOrder.sorted(["old", "new", "middle"], metadata: metadata)
        XCTAssertEqual(sorted, ["new", "middle", "old"])
    }

    func test_branchesWithoutMetadataKeepInputOrderAtEnd() {
        let metadata: [String: GitBranchMetadata] = [
            "b": metadata(500),
        ]

        // 元数据未加载时(空字典)保持原顺序:首帧不闪跳。
        XCTAssertEqual(
            BranchActivityOrder.sorted(["a", "b", "c"], metadata: [:]),
            ["a", "b", "c"]
        )
        // 部分加载:有时间的在前,无时间的按原相对顺序垫底。
        XCTAssertEqual(
            BranchActivityOrder.sorted(["a", "b", "c"], metadata: metadata),
            ["b", "a", "c"]
        )
    }

    func test_sameDateFallsBackToInputOrder() {
        let metadata: [String: GitBranchMetadata] = [
            "zeta": metadata(100),
            "alpha": metadata(100),
        ]

        XCTAssertEqual(
            BranchActivityOrder.sorted(["zeta", "alpha"], metadata: metadata),
            ["zeta", "alpha"]
        )
    }
}
