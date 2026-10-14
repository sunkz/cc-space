import XCTest
@testable import CCSpace

final class RepositoryConfigPresentationStateTests: XCTestCase {
    func test_searchStateReturnsAllRepositoriesWhenSearchTextIsEmpty() {
        let repositories = [
            makeRepository(name: "api", url: "git@github.com:org/api.git"),
            makeRepository(name: "web", url: "git@gitlab.example.com:team/web.git"),
        ]

        let state = RepositorySearchPresentationState(
            repositories: repositories,
            searchText: "   "
        )

        XCTAssertEqual(state.filteredRepositories, repositories)
        XCTAssertEqual(state.emptyTitle, "暂无仓库配置")
        XCTAssertEqual(state.emptySubtitle, RepositorySearchPresentationState.emptyLibrarySubtitle)
    }

    /// 仓库池本来就是空的:搜索框此时已经不出现,不能再回"未找到匹配仓库"
    /// (那会让用户去找一个界面上不存在的输入框)。
    func test_searchStateFallsBackToEmptyLibraryCopyWhenPoolIsEmpty() {
        let state = RepositorySearchPresentationState(repositories: [], searchText: "api")

        XCTAssertTrue(state.filteredRepositories.isEmpty)
        XCTAssertEqual(state.emptyTitle, "暂无仓库配置")
        XCTAssertEqual(state.emptySubtitle, RepositorySearchPresentationState.emptyLibrarySubtitle)
    }

    func test_searchMatchesPredicateIsTheOneSourceForVisibilityChecks() {
        let repository = makeRepository(name: "api", url: "git@github.com:org/api.git")

        XCTAssertTrue(RepositorySearchPresentationState.matches(repository, keyword: "API"))
        XCTAssertTrue(RepositorySearchPresentationState.matches(repository, keyword: "ORG/api"))
        XCTAssertFalse(RepositorySearchPresentationState.matches(repository, keyword: "web"))
    }

    func test_searchStateMatchesRepositoryNameAndURLCaseInsensitively() {
        let apiRepository = makeRepository(name: "api", url: "git@github.com:org/api.git")
        let webRepository = makeRepository(name: "web", url: "git@gitlab.example.com:team/frontend.git")

        let nameState = RepositorySearchPresentationState(
            repositories: [apiRepository, webRepository],
            searchText: "API"
        )
        let urlState = RepositorySearchPresentationState(
            repositories: [apiRepository, webRepository],
            searchText: "frontend"
        )

        XCTAssertEqual(nameState.filteredRepositories, [apiRepository])
        XCTAssertEqual(urlState.filteredRepositories, [webRepository])
    }

    func test_searchStateShowsSearchEmptyStateWhenNoRepositoryMatches() {
        let state = RepositorySearchPresentationState(
            repositories: [makeRepository(name: "api", url: "git@github.com:org/api.git")],
            searchText: "mobile"
        )

        XCTAssertTrue(state.filteredRepositories.isEmpty)
        XCTAssertEqual(state.emptyTitle, "未找到匹配仓库")
        XCTAssertEqual(state.emptySubtitle, "试试仓库名称或地址中的关键词。")
    }

    func test_backToTopOnlyAppearsWhenFilteredListExceedsThreshold() {
        let threshold = RepositorySearchPresentationState.backToTopThreshold
        let repositories = (0..<threshold).map { index in
            makeRepository(name: "repo-\(index)", url: "git@github.com:org/repo-\(index).git")
        }

        // 恰好等于阈值:滚不出首屏,不显示。
        XCTAssertFalse(
            RepositorySearchPresentationState(repositories: repositories, searchText: "").showsBackToTop
        )
        let oneMore = repositories + [
            makeRepository(name: "extra", url: "git@github.com:org/extra.git"),
        ]
        XCTAssertTrue(
            RepositorySearchPresentationState(repositories: oneMore, searchText: "").showsBackToTop
        )
        // 搜索收窄到阈值以内:即使总数超阈值也不显示(按过滤后条数判断)。
        XCTAssertFalse(
            RepositorySearchPresentationState(repositories: oneMore, searchText: "extra").showsBackToTop
        )
    }

    func test_branchPillGroupKeepsAllBranchesWhenWithinThreshold() {
        let state = RepositoryBranchPillGroupPresentationState(
            branches: ["develop", "release", "staging"]
        )

        XCTAssertEqual(state.visibleBranches, ["develop", "release", "staging"])
        XCTAssertTrue(state.overflowBranches.isEmpty)
        XCTAssertNil(state.overflowCountText)
        XCTAssertNil(state.overflowQuickHelpText)
    }

    func test_branchPillGroupCollapsesOverflowIntoCountPill() {
        let state = RepositoryBranchPillGroupPresentationState(
            branches: ["develop", "release", "staging", "hotfix", "next"]
        )

        XCTAssertEqual(state.visibleBranches, ["develop", "release", "staging"])
        XCTAssertEqual(state.overflowBranches, ["hotfix", "next"])
        XCTAssertEqual(state.overflowCountText, "+2")
        XCTAssertEqual(
            state.overflowQuickHelpText,
            "MR 目标分支（已折叠）：\nhotfix\nnext",
            "折叠胶囊的悬停提示须逐条列出被折叠的分支"
        )
    }

    func test_branchPillGroupWithNoBranchesIsEmpty() {
        let state = RepositoryBranchPillGroupPresentationState(branches: [])

        XCTAssertTrue(state.visibleBranches.isEmpty)
        XCTAssertNil(state.overflowCountText)
    }

    func test_addStateTrimsWhitespaceBeforeAllowingSubmit() {
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "   ").canSubmit)
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: " git@github.com:org/blog.git ").canSubmit)
    }

    /// 表单的地址口径必须自己判定形态:`GitURLParser.repositoryName` 有 legacy 兜底、
    /// `validateRemoteURL` 只防选项注入,两者都会把 "abc" 当合法输入放行。
    func test_addStateRejectsUnparseableGitURL() {
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "abc").canSubmit)
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "abc").isURLFormatValid)
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "ftp://host/repo.git").canSubmit)
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "git@host:repo dir").canSubmit, "含空格")
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: "https://github.com/org/blog.git").canSubmit)
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: "git@github.com:org/blog.git").canSubmit)
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: "/tmp/repos/blog.git").canSubmit, "本地路径")
        // 空输入是"还没输入",不给提交但也不报格式错。
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: "   ").isURLFormatValid)
    }

    /// 只到 host 的半成品、浏览器里的网页地址、相对路径、`..` 越界路径都不算仓库地址:
    /// 它们此前能建档,直到克隆那一步才报错。
    func test_addStateRejectsAddressThatDoesNotPointAtRepository() {
        for gitURL in [
            "https://github.com",       // 没有仓库路径
            "git@github.com:",          // 冒号后为空
            "git@:",                    // host 为空
            "@github.com:org/repo.git", // 用户名为空
            "https://",                 // 只有协议头
            "/",
            "~/",
            "./blog.git",               // 相对路径:git 子进程 cwd 是临时目录,永远克隆不下来
            "../blog.git",
            "/tmp/../etc/passwd",       // 绝对路径的承诺不该指到任意目录之外
            "~/repos/../evil.git",
            "https://github.com/org/repo/blob/main/README.md",  // 浏览器里的文件页
            "https://github.com/org/repo/settings/keys",
            "https://github.com/org/repo/issues",               // 三段:末段也是网页路径
            "https://github.com/org/repo/releases",
            "https://gitlab.com/group/proj/-/merge_requests/new",
            "https://host/projects/PROJ/repos/repo/browse",
            "git@github.com:org/repo/pulls",
            "https://host/o/x/blob",                             // ≥3 段时 UI 段落在末段也拒
            "https://github.com/new",                           // 公共域单段是站点页面
            "https://github.com/features",
            "https://github.com/org/repo.git?ref=main",         // query 会被解析器无声吞掉
            "https://github.com/org/repo#readme",
            "https://github.com/.git",                          // 剥掉 .git 后路径为空
            "git@github.com:.git",
            "/tmp/.git",                                        // 本地路径同口径
            "/tmp/o/.git",
            "~admin/repos/blog.git",                            // `~用户` 形态:git 与 app 都不展开,入库即死地址
            "file://",
            "file://tmp/repo.git",                              // 两斜杠形态 git 会吞掉 host
            "github.com:",                                      // 省用户名但路径为空
            "v2.0:beta",                                        // 省用户名时冒号前必须像主机名
            "abc:def",
            "C:repos/x.git",
            ":org/repo.git",
        ] {
            XCTAssertFalse(
                RepositoryAddPresentationState(gitURL: gitURL).canSubmit,
                "\(gitURL) 不该被当成仓库地址"
            )
        }
    }

    func test_addStateAcceptsCommonRepositoryAddressShapes() {
        for gitURL in [
            "https://github.com/org/blog.git",
            "ssh://git@github.com:22/org/blog.git",
            "HTTPS://GitHub.COM/Org/Repo.git",   // 大写协议头
            "git@github.com:org/blog.git",
            "github.com:org/blog.git",             // scp 省略用户名:git 走 SSH 默认用户
            "git.internal:team/blog.git",
            "git@gitlab.example.com:group/sub/group/repo.git",  // 子组
            "git@host:/srv/git/blog.git",   // 远端绝对路径
            "https://host/org/my%20repo.git",
            "file:///private/tmp/repos/blog.git",
            "/tmp/repos/blog.git",
            "~/repos/blog.git",
            "~/Documents/My Projects/blog.git",  // 本地路径允许空格
            "/tmp/blog copy.git",
            "file:///tmp/My Projects/blog.git",  // file:// 是本地路径的规范写法,口径一致
            "https://github.com/team/settings",  // 两段:末段就是仓库名,不判 UI 段
            "https://host/blob",                 // 同上:自建 host 上仓库真叫 blob
            "https://host/blob/o",               // 首段是 owner/分组名,一律不判 UI 段
            "https://git.internal/repo",         // 自建 host 单段仓库是合法形态
        ] {
            XCTAssertTrue(
                RepositoryAddPresentationState(gitURL: gitURL).canSubmit,
                "\(gitURL) 是合法仓库地址"
            )
        }
    }

    // MARK: - 地址框下方那一行提示

    func test_addFieldHintDistinguishesNotYetTypedFromRejectedInput() {
        let idle = RepositoryAddFieldHint(gitURL: "   ", submitAttempted: false, repositories: [])
        XCTAssertEqual(idle.style, .neutral)
        // 空框不复述占位词:text 为空串,调用方据此把提示行整行收掉。
        XCTAssertEqual(idle.text, "")
        XCTAssertNil(idle.duplicateRepositoryID)

        // 空框点过「新增」才是错误,且要说"没填"而不是"填错了"。
        let missing = RepositoryAddFieldHint(gitURL: "   ", submitAttempted: true, repositories: [])
        XCTAssertEqual(missing.style, .error)
        XCTAssertEqual(missing.text, RepositoryAddFieldHint.missingInputText)

        let invalid = RepositoryAddFieldHint(gitURL: "abcabc", submitAttempted: false, repositories: [])
        XCTAssertEqual(invalid.style, .error)
        XCTAssertEqual(invalid.text, RepositoryURLFormat.invalidMessage)
    }

    func test_addFieldHintPreviewsNameAndSourceBeforeSubmitting() {
        func hint(_ gitURL: String) -> RepositoryAddFieldHint {
            RepositoryAddFieldHint(gitURL: gitURL, submitAttempted: false, repositories: [])
        }

        XCTAssertEqual(hint(" git@github.com:org/blog.git ").text, "将创建 blog · github.com", "前后空白不参与解析")
        XCTAssertEqual(hint("https://gitlab.example.com/team/web.git").text, "将创建 web · gitlab.example.com")
        // 本地路径没有 Web 主页,来源写「本地目录」,否则用户以为要联网。
        XCTAssertEqual(hint("/tmp/repos/blog.git").text, "将创建 blog · 本地目录")
    }

    /// 判重复必须与 Store 建档同一套归一化(去 `.git`/大小写、展开 `~/`),
    /// 否则提示说"将创建",点下去却撞 `duplicateURL` 红条——同一件事两个答案。
    func test_addFieldHintFlagsDuplicateUsingSameNormalizationAsStore() {
        let sshRepository = makeRepository(name: "blog", url: "git@github.com:org/blog.git")
        let localRepository = makeRepository(
            name: "local-blog",
            url: NSHomeDirectory() + "/repos/blog.git"
        )

        let sshDuplicate = RepositoryAddFieldHint(
            gitURL: "git@github.com:org/blog",   // 少 .git 后缀
            submitAttempted: false,
            repositories: [sshRepository]
        )
        XCTAssertEqual(sshDuplicate.style, .duplicate)
        XCTAssertEqual(sshDuplicate.text, "该地址已存在：blog")
        XCTAssertEqual(sshDuplicate.duplicateRepositoryID, sshRepository.id)

        // 家目录写法 vs 已存的绝对路径:同一条地址的两种写法。
        XCTAssertEqual(
            RepositoryAddFieldHint(
                gitURL: "~/repos/blog.git",
                submitAttempted: false,
                repositories: [localRepository]
            ).style,
            .duplicate
        )
    }

    func test_backupExportStateUsesTimestampedDefaultName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let now = calendar.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2024,
                month: 4,
                day: 20,
                hour: 0,
                minute: 0,
                second: 0
            )
        ) ?? .distantPast

        XCTAssertEqual(
            RepositoryBackupExportPresentationState.defaultFileName(now: now),
            "ccspace-git-repositories-20240420-000000.json"
        )
    }

    func test_feedbackFactoryBuildsRepositorySuccessMessages() {
        XCTAssertEqual(
            RepositoryConfigFeedbackFactory.addSuccess(repositoryName: "blog"),
            CCSpaceFeedback(style: .success, message: "已新增 blog")
        )
        XCTAssertEqual(
            RepositoryConfigFeedbackFactory.deleteSuccess(repositoryName: "blog"),
            CCSpaceFeedback(style: .success, message: "已删除 blog")
        )
    }

    func test_deleteStateRequiresConfirmationWhenRepositoryUnused() {
        let repository = makeRepository(name: "blog", url: "git@github.com:org/blog.git")

        let state = RepositoryDeletePresentationState(
            repository: repository,
            workplaces: []
        )

        XCTAssertEqual(state.repositoryID, repository.id)
        XCTAssertEqual(state.title, "删除 blog")
        XCTAssertEqual(state.message, "删除后将无法在新工作区中继续选择该仓库，此操作不可撤销。")
        XCTAssertEqual(state.confirmLabel, "确认删除")
        XCTAssertFalse(state.isBlocked)
    }

    func test_deleteStateBlocksRemovalWhenRepositoryStillReferenced() {
        let repository = makeRepository(name: "blog", url: "git@github.com:org/blog.git")
        let workplace = Workplace(
            id: UUID(),
            name: "iOS 主线",
            path: "/tmp/workspaces/ios-main",
            selectedRepositoryIDs: [repository.id],
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let state = RepositoryDeletePresentationState(
            repository: repository,
            workplaces: [workplace]
        )

        XCTAssertEqual(state.title, "无法删除 blog")
        XCTAssertEqual(
            state.message,
            """
            以下工作区仍在使用该仓库，请先编辑工作区移除后再删除。
            工作区：iOS 主线
            """
        )
        XCTAssertEqual(state.confirmLabel, "")
        XCTAssertTrue(state.isBlocked)
    }

    // MARK: - MR 目标分支面板状态机

    func test_mrPanelSwitchingRowsDropsPreviousRemoteListAndInflightResult() throws {
        let rowA = UUID()
        let rowB = UUID()
        var panel = MRBranchPanelState()

        panel.open(repositoryID: rowA)
        let sessionA = try XCTUnwrap(panel.sessionToken(for: rowA))
        let generationA = try XCTUnwrap(panel.beginLoad(sessionA))
        panel.finishLoad(sessionA, generation: generationA, branches: ["main"])
        XCTAssertEqual(panel.remoteBranches, ["main"])
        XCTAssertFalse(panel.isLoadingRemoteBranches)

        // 换到 B:名单立刻清空(B 的探测回来前只能显示加载态),
        // 且 A 的迟到结果不得写进 B 的面板——否则点一行就把 A 的分支名写进 B 的配置。
        XCTAssertNil(
            panel.beginLoad(MRBranchPanelState.Session(repositoryID: rowB, identifier: UUID())),
            "B 还没打开,不该允许发起探测"
        )
        panel.open(repositoryID: rowB)
        XCTAssertNil(panel.remoteBranches)
        panel.finishLoad(sessionA, generation: generationA, branches: ["ghost"])
        XCTAssertNil(panel.remoteBranches, "旧面板迟到结果被归属令牌拦下")
    }

    func test_mrPanelCloseAndCancelOnlyAffectTheOpenedPresentation() throws {
        let rowA = UUID()
        let rowB = UUID()
        var panel = MRBranchPanelState()
        panel.open(repositoryID: rowA)
        let sessionA = try XCTUnwrap(panel.sessionToken(for: rowA))
        panel.open(repositoryID: rowB)
        let sessionB = try XCTUnwrap(panel.sessionToken(for: rowB))

        // 旧面板迟到的 binding 回写 / onDisappear 都不能动新面板。
        panel.close(repositoryID: rowA)
        XCTAssertTrue(panel.isOpen(for: rowB))
        let generationB = try XCTUnwrap(panel.beginLoad(sessionB))
        panel.cancelLoad(sessionA)
        XCTAssertTrue(panel.isLoadingRemoteBranches, "A 的取消不该作废 B 在途的探测")
        panel.finishLoad(sessionB, generation: generationB, branches: ["dev"])
        XCTAssertEqual(panel.remoteBranches, ["dev"])

        panel.close(repositoryID: rowB)
        XCTAssertFalse(panel.isOpen(for: rowB))
        XCTAssertNil(panel.remoteBranches)
        XCTAssertFalse(panel.isLoadingRemoteBranches)
    }

    /// 同一行"关了又开"(连点两次 MR 按钮)时行 ID 没变:旧内容迟到的 cancel 必须按
    /// **呈现快照**判定,否则它正好命中新面板,把刚发起的 ls-remote 打成"远端没有分支"。
    func test_mrPanelSameRowReopenIgnoresPreviousPresentationCancel() throws {
        let row = UUID()
        var panel = MRBranchPanelState()
        panel.open(repositoryID: row)
        let firstSession = try XCTUnwrap(panel.sessionToken(for: row))
        panel.close(repositoryID: row)
        panel.open(repositoryID: row)
        let secondSession = try XCTUnwrap(panel.sessionToken(for: row))
        XCTAssertNotEqual(firstSession, secondSession)

        let generation = try XCTUnwrap(panel.beginLoad(secondSession))
        panel.cancelLoad(firstSession)
        XCTAssertTrue(panel.isLoadingRemoteBranches)
        panel.finishLoad(secondSession, generation: generation, branches: ["main"])
        XCTAssertEqual(panel.remoteBranches, ["main"])
    }

    /// 探测失败(nil)与"远端确无分支"([])必须可区分:失败要保留上一次名单,
    /// 否则一次网络抖动就把可用列表打成空,而只读胶囊没有第二条移除入口。
    func test_mrPanelFailedProbeKeepsPreviousRemoteList() throws {
        let row = UUID()
        var panel = MRBranchPanelState()
        panel.open(repositoryID: row)
        let session = try XCTUnwrap(panel.sessionToken(for: row))
        let first = try XCTUnwrap(panel.beginLoad(session))
        panel.finishLoad(session, generation: first, branches: ["main", "dev"])

        let second = try XCTUnwrap(panel.beginLoad(session))
        panel.finishLoad(session, generation: second, branches: nil)

        XCTAssertEqual(panel.remoteBranches, ["main", "dev"])
        XCTAssertFalse(panel.isLoadingRemoteBranches)
    }

    // MARK: - MR 目标分支点选与胶囊

    func test_mrBranchToggleRemovesExistingAndAppendsNewAtTail() {
        XCTAssertEqual(
            MRBranchToggle.nextBranches(current: ["main", "dev"], toggled: "main"),
            ["dev"],
            "移除保序"
        )
        XCTAssertEqual(
            MRBranchToggle.nextBranches(current: ["dev"], toggled: "main"),
            ["dev", "main"],
            "追加到末尾:首条是工作区行「创建 MR」的默认目标,顺序即优先级"
        )
        XCTAssertEqual(
            MRBranchToggle.nextBranches(current: [], toggled: "main"),
            ["main"]
        )
    }

    func test_mrChipDisplayHidesDefaultBranchTolerantly() {
        XCTAssertEqual(
            MRBranchChipDisplay.visibleBranches(branches: ["main", "dev"], defaultBranch: "main"),
            ["dev"]
        )
        XCTAssertEqual(
            MRBranchChipDisplay.visibleBranches(branches: ["main", "dev"], defaultBranch: " main "),
            ["dev"],
            "脏值(带空格的历史数据)不该让同一分支既显示又被当成默认"
        )
        XCTAssertEqual(
            MRBranchChipDisplay.visibleBranches(branches: ["main"], defaultBranch: nil),
            ["main"],
            "默认分支尚未回写时不该把已配的 MR 分支藏掉"
        )
    }

    // MARK: - 默认分支回写判定

    func test_defaultBranchWriteDecisionGuardsProbeResult() {
        XCTAssertEqual(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: "  main  ",
                recordedGitURL: "git@github.com:org/api.git",
                recordedDefaultBranch: nil,
                probedGitURL: "git@github.com:org/api.git"
            ),
            "main"
        )
        XCTAssertNil(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: "   ",
                recordedGitURL: "git@github.com:org/api.git",
                recordedDefaultBranch: nil,
                probedGitURL: "git@github.com:org/api.git"
            ),
            "探测结果为空白不写"
        )
        XCTAssertNil(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: nil,
                recordedGitURL: nil,
                recordedDefaultBranch: nil,
                probedGitURL: "git@github.com:org/api.git"
            ),
            "仓库已删不写"
        )
        XCTAssertNil(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: "main",
                recordedGitURL: "git@github.com:org/other.git",
                recordedDefaultBranch: nil,
                probedGitURL: "git@github.com:org/api.git"
            ),
            "地址已换,不把旧远端的默认分支落到新配置上"
        )
        XCTAssertNil(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: "main",
                recordedGitURL: "git@github.com:org/api.git",
                recordedDefaultBranch: "master",
                probedGitURL: "git@github.com:org/api.git"
            ),
            "在途探测期间由导入/合并写进来的值不能被盖掉:这里是补空,不是纠正"
        )
        XCTAssertEqual(
            DefaultBranchWriteDecision.branchToWrite(
                probeResult: "main",
                recordedGitURL: "https://github.com/org/repo",
                recordedDefaultBranch: nil,
                probedGitURL: "https://github.com/org/repo.git/"
            ),
            "main",
            "比较要走 Store 的归一口径:裸串比较会把同一个远端误判成「地址变了」而静默不回写"
        )
    }

    private func makeRepository(name: String, url: String) -> RepositoryConfig {
        RepositoryConfig(
            id: UUID(),
            gitURL: url,
            repoName: name,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
