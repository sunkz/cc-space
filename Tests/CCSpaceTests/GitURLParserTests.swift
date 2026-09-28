import XCTest
@testable import CCSpace

final class GitURLParserTests: XCTestCase {
    func test_extractsRepositoryNameFromSSHURL() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryName(from: "git@github.com:org/mobile-app.git"),
            "mobile-app"
        )
    }

    func test_extractsRepositoryNameFromNestedHTTPSURL() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryName(from: "https://gitlab.example.com/mobile/ios/client.git"),
            "client"
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

    func test_buildsRepositoryWebURLFromSCPStyleSSH() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryWebURL(from: "git@github.com:org/mobile-app.git").absoluteString,
            "https://github.com/org/mobile-app"
        )
    }

    func test_buildsRepositoryWebURLFromSSHSchemeWithoutLeakingSSHPort() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryWebURL(from: "ssh://git@code.example.com:2222/mobile/app.git").absoluteString,
            "https://code.example.com/mobile/app"
        )
    }

    func test_buildsRepositoryWebURLKeepingHTTPSPort() throws {
        XCTAssertEqual(
            try GitURLParser.repositoryWebURL(from: "https://gitlab.example.com:8443/team/repo.git").absoluteString,
            "https://gitlab.example.com:8443/team/repo"
        )
    }

    func test_rejectsRepositoryWebURLForLocalPath() {
        XCTAssertThrowsError(try GitURLParser.repositoryWebURL(from: "/tmp/local-repo.git")) { error in
            XCTAssertEqual(error.localizedDescription, "无法解析仓库地址")
        }
    }
}

extension GitURLParserTests {
    /// provider 判定是实现细节,走公开的 MR 链接生成口径断言可观察行为。
    func test_mergeRequestURLUsesExactHostMatching() throws {
        // 公共平台:精确命中。
        let gh = try GitURLParser.mergeRequestURL(
            from: "git@github.com:org/app.git", sourceBranch: "feat", targetBranch: "main"
        )
        XCTAssertTrue(gh.absoluteString.contains("/compare/main...feat"))

        let selfHostedGitLab = try GitURLParser.mergeRequestURL(
            from: "https://gitlab.acme.com/team/app.git", sourceBranch: "feat", targetBranch: "main"
        )
        XCTAssertTrue(selfHostedGitLab.absoluteString.contains("/merge_requests/new"))

        // 子串误分类回归锁:含 github 子串的自建域不得按 GitHub compare 格式生成。
        let proxy = try GitURLParser.mergeRequestURL(
            from: "https://my-github-proxy.internal/org/app.git", sourceBranch: "feat", targetBranch: "main"
        )
        XCTAssertFalse(proxy.absoluteString.contains("/compare/"))

        // 首段不是 gitlab 的无关自建域按 GitLab 兜底(有意取舍:MR 失败仅少快捷入口;
        // P2-30 曾建议改报错,因 MergeRequestServiceTests 锁定兜底行为而维持现状)。
        let unknown = try GitURLParser.mergeRequestURL(
            from: "https://code.example.org/o/r.git", sourceBranch: "feat", targetBranch: "main"
        )
        XCTAssertTrue(unknown.absoluteString.contains("/merge_requests/new"))

        // 明确不支持的平台必须报错而不是生成假链接。
        XCTAssertThrowsError(try GitURLParser.mergeRequestURL(
            from: "git@bitbucket.org:org/app.git", sourceBranch: "feat", targetBranch: "main"
        ))
    }
}
