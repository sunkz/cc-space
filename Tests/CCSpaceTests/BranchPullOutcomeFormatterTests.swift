import XCTest
@testable import CCSpace

final class BranchPullOutcomeFormatterTests: XCTestCase {
    func test_singleRepository_allTrivial_returnsNil() {
        let outcome = GitPullAllBranchesOutcome(
            currentBranch: "main",
            currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
            otherBranchOutcomes: [
                GitBranchPullOutcome(branch: "feat", status: .alreadyUpToDate, errorMessage: nil)
            ],
            primaryError: nil
        )
        XCTAssertNil(BranchPullOutcomeFormatter.detailsForSingleRepository(outcome))
    }

    func test_singleRepository_mixedOutcomes_listsNonTrivial() throws {
        let outcome = GitPullAllBranchesOutcome(
            currentBranch: "main",
            currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
            otherBranchOutcomes: [
                GitBranchPullOutcome(branch: "alpha", status: .pulled, errorMessage: nil),
                GitBranchPullOutcome(branch: "beta", status: .skippedDiverged, errorMessage: nil),
                GitBranchPullOutcome(branch: "gamma", status: .skippedNoUpstream, errorMessage: nil),
                GitBranchPullOutcome(branch: "delta", status: .alreadyUpToDate, errorMessage: nil)
            ],
            primaryError: nil
        )
        let text = try XCTUnwrap(BranchPullOutcomeFormatter.detailsForSingleRepository(outcome))
        XCTAssertTrue(text.contains("alpha 已更新"))
        XCTAssertTrue(text.contains("beta 跳过(发散)"))
        XCTAssertTrue(text.contains("gamma 跳过(无 upstream)"))
        XCTAssertFalse(text.contains("delta"))
    }

    func test_singleRepository_failureIncludesErrorMessage() throws {
        let outcome = GitPullAllBranchesOutcome(
            currentBranch: "main",
            currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
            otherBranchOutcomes: [
                GitBranchPullOutcome(branch: "alpha", status: .failed, errorMessage: "permission denied")
            ],
            primaryError: nil
        )
        let text = try XCTUnwrap(BranchPullOutcomeFormatter.detailsForSingleRepository(outcome))
        XCTAssertTrue(text.contains("alpha 失败"))
        XCTAssertTrue(text.contains("permission denied"))
    }

    func test_singleRepository_currentBranchOutcomeIsNotListed() {
        // 即使当前分支失败，formatter 也不应在 details 列出 — 由顶层 failedNames 反映
        let outcome = GitPullAllBranchesOutcome(
            currentBranch: "main",
            currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .failed, errorMessage: "merge conflict"),
            otherBranchOutcomes: [],
            primaryError: nil
        )
        XCTAssertNil(BranchPullOutcomeFormatter.detailsForSingleRepository(outcome))
    }

    func test_bulk_emptyReturnsNil() {
        XCTAssertNil(BranchPullOutcomeFormatter.detailsForBulk([]))
    }

    func test_bulk_listsRepositoryNameHeader_skipsTrivialRepos() throws {
        let summaries = [
            RepositoryBranchPullOutcomeSummary(
                repositoryName: "api",
                outcome: GitPullAllBranchesOutcome(
                    currentBranch: "main",
                    currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
                    otherBranchOutcomes: [
                        GitBranchPullOutcome(branch: "alpha", status: .skippedDiverged, errorMessage: nil)
                    ],
                    primaryError: nil
                )
            ),
            RepositoryBranchPullOutcomeSummary(
                repositoryName: "web",
                outcome: GitPullAllBranchesOutcome(
                    currentBranch: "main",
                    currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
                    otherBranchOutcomes: [],
                    primaryError: nil
                )
            )
        ]
        let text = try XCTUnwrap(BranchPullOutcomeFormatter.detailsForBulk(summaries))
        XCTAssertTrue(text.contains("api"))
        XCTAssertTrue(text.contains("alpha 跳过(发散)"))
        // web 没有非平凡条目，不应出现
        XCTAssertFalse(text.contains("web："))
    }

    func test_singleRepository_failureCollapsesMultilineErrorMessage() throws {
        let outcome = GitPullAllBranchesOutcome(
            currentBranch: "main",
            currentBranchOutcome: GitBranchPullOutcome(branch: "main", status: .pulled, errorMessage: nil),
            otherBranchOutcomes: [
                GitBranchPullOutcome(branch: "alpha", status: .failed, errorMessage: "permission denied\n  on refs/heads/alpha\n")
            ],
            primaryError: nil
        )
        let text = try XCTUnwrap(BranchPullOutcomeFormatter.detailsForSingleRepository(outcome))
        XCTAssertFalse(text.contains("\n  on refs/heads"), "错误消息不应保留嵌入的换行,以免破坏 details 缩进")
        XCTAssertTrue(text.contains("permission denied on refs/heads/alpha"))
    }
}
