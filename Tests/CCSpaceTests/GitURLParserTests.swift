import XCTest
@testable import CCSpace

final class GitURLParserTests: XCTestCase {
    func test_extractsRepositoryNameFromSSHURL() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryName(from: "git@github.com:org/mobile-app.git"),
            "mobile-app"
        )
    }

    func test_buildsGitLabMergeRequestURLFromSSHURL() throws {
        let url = try GitURLParser.mergeRequestURL(
            from: "git@code.example.com:mobile/app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://code.example.com/mobile/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )
    }

    func test_buildsGitLabMergeRequestURLWithoutLeakingSSHPort() throws {
        let url = try GitURLParser.mergeRequestURL(
            from: "ssh://git@code.example.com:2222/mobile/app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://code.example.com/mobile/app/merge_requests/new?merge_request%5Bsource_branch%5D=feature/demo&merge_request%5Btarget_branch%5D=main"
        )
    }

    func test_buildsGitHubCompareURLFromHTTPSURL() throws {
        let url = try GitURLParser.mergeRequestURL(
            from: "https://github.com/org/mobile-app.git",
            sourceBranch: "feature/demo",
            targetBranch: "main"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/org/mobile-app/compare/main...feature/demo?expand=1"
        )
    }

    func test_rejectsMergeRequestWhenAlreadyOnDefaultBranch() {
        XCTAssertThrowsError(
            try GitURLParser.mergeRequestURL(
                from: "git@gitlab.example.com:team/mobile-app.git",
                sourceBranch: "main",
                targetBranch: "main"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "当前已在默认分支，无法创建 MR")
        }
    }

    func test_rejectsUnsupportedBitbucketMergeRequestURL() {
        XCTAssertThrowsError(
            try GitURLParser.mergeRequestURL(
                from: "https://bitbucket.example.com/team/mobile-app.git",
                sourceBranch: "feature/demo",
                targetBranch: "main"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "暂不支持为 Bitbucket 仓库生成 MR 链接")
        }
    }
}
