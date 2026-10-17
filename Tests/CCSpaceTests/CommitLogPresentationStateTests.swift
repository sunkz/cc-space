import XCTest
@testable import CCSpace

final class CommitLogPresentationStateTests: XCTestCase {
    private func makeCommits() -> [GitCommitEntry] {
        [
            GitCommitEntry(
                hash: "aaaaaa1111111111",
                subject: "fix: 修复登录崩溃",
                author: "张三",
                date: Date(timeIntervalSinceNow: -60),
                filesChanged: 2,
                insertions: 10,
                deletions: 3
            ),
            GitCommitEntry(
                hash: "bbbbbb2222222222",
                subject: "feat: add search",
                author: "Alice",
                date: Date(timeIntervalSinceNow: -3600),
                filesChanged: 1,
                insertions: 5,
                deletions: 0
            ),
        ]
    }

    func test_commitsArePassedThroughUnfiltered() {
        // 关键词过滤已下推到 git:展示层再筛一遍会把 git 命中的**正文**提交判掉
        // (本类型只持有 subject/author/hash)。因此列表原样透传,与搜索词无关。
        let state = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "不存在",
            scope: .all,
            hasUpstream: true
        )

        XCTAssertEqual(state.visibleCommits.count, 2)
        XCTAssertEqual(state.countLabel, "匹配 2 条提交")
    }

    func test_emptySearchUsesPlainCountLabel() {
        let state = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "   ",
            scope: .all,
            hasUpstream: true
        )

        XCTAssertEqual(state.visibleCommits.count, 2)
        XCTAssertEqual(state.countLabel, "2 条提交")
    }

    func test_searchEmptyTextTellsUserTheWholeHistoryWasSearched() {
        let noMatch = CommitLogPresentationState(
            commits: [],
            searchText: "不存在",
            scope: .all,
            hasUpstream: true
        )
        XCTAssertTrue(noMatch.visibleCommits.isEmpty)
        XCTAssertEqual(noMatch.emptyTitle, "未找到匹配提交")
        XCTAssertTrue(noMatch.emptySubtitle.contains("全部历史"))

        // 搜索态优先于"没有未推送的提交":空列表在勾选筛选时同样该说明搜过什么。
        let unpushedNoMatch = CommitLogPresentationState(
            commits: [],
            searchText: "不存在",
            scope: .unpushedOnly,
            hasUpstream: true
        )
        XCTAssertEqual(unpushedNoMatch.emptyTitle, "未找到匹配提交")
        XCTAssertEqual(unpushedNoMatch.countLabel, "匹配 0 条未推送提交")
    }

    func test_unpushedScopeUsesDedicatedCountLabelAndEmptyText() {
        let withCommits = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .unpushedOnly,
            hasUpstream: true
        )
        XCTAssertEqual(withCommits.countLabel, "2 条未推送提交")

        let empty = CommitLogPresentationState(
            commits: [],
            searchText: "",
            scope: .unpushedOnly,
            hasUpstream: true
        )
        XCTAssertTrue(empty.visibleCommits.isEmpty)
        XCTAssertEqual(empty.emptyTitle, "没有未推送的提交")
        XCTAssertEqual(empty.emptySubtitle, "当前分支的提交都已推送到远端")

        let emptyAll = CommitLogPresentationState(
            commits: [],
            searchText: "",
            scope: .all,
            hasUpstream: true
        )
        XCTAssertEqual(emptyAll.emptyTitle, "暂无提交记录")
        XCTAssertEqual(emptyAll.emptySubtitle, "")
    }

    func test_unpushedToggleDisabledWithoutUpstream() {
        let noUpstream = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .all,
            hasUpstream: false
        )
        XCTAssertFalse(noUpstream.canFilterUnpushed)
        XCTAssertTrue(noUpstream.unpushedToggleHelp.contains("未关联远端"))

        let hasUpstream = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .all,
            hasUpstream: true
        )
        XCTAssertTrue(hasUpstream.canFilterUnpushed)
        XCTAssertTrue(hasUpstream.unpushedToggleHelp.contains("未推送"))
    }

    func test_unpushedToggleHelpAttributesRemoteTrackingRefCorrectly() {
        // 浏览 origin/x 远端跟踪分支时没有"当前分支"可言,
        // 提示不能误归因为"当前分支未关联远端"。
        let remoteTracking = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .all,
            hasUpstream: false,
            isRemoteTrackingRef: true
        )
        XCTAssertFalse(remoteTracking.canFilterUnpushed)
        XCTAssertTrue(remoteTracking.unpushedToggleHelp.contains("远端跟踪分支"))
        XCTAssertFalse(remoteTracking.unpushedToggleHelp.contains("未关联远端"))

        // 本地分支无上游时仍走原归因。
        let localNoUpstream = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .all,
            hasUpstream: false,
            isRemoteTrackingRef: false
        )
        XCTAssertTrue(localNoUpstream.unpushedToggleHelp.contains("未关联远端"))

        // 有上游时优先给正常提示(防御 isRemoteTrackingRef 误传)。
        let withUpstream = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "",
            scope: .all,
            hasUpstream: true,
            isRemoteTrackingRef: true
        )
        XCTAssertTrue(withUpstream.canFilterUnpushed)
        XCTAssertTrue(withUpstream.unpushedToggleHelp.contains("未推送"))
    }
}

final class BranchDeleteCandidateTests: XCTestCase {
    func test_localWithoutRemoteSameNameKeepsPlainDeleteText() {
        let candidate = BranchDeleteCandidate.local(branch: "feature/a", remoteBranch: nil)
        XCTAssertEqual(candidate.alertTitle, "删除分支 feature/a？")
        XCTAssertEqual(candidate.alertMessage, "删除该分支后不可恢复。")
    }

    func test_localWithRemoteSameNameWarnsAboutCollaborators() {
        let candidate = BranchDeleteCandidate.local(branch: "feature/a", remoteBranch: "feature/a")
        XCTAssertEqual(candidate.alertTitle, "删除分支 feature/a？")
        XCTAssertTrue(candidate.alertMessage.contains("同名"))
        XCTAssertTrue(candidate.alertMessage.contains("协作者"))
    }

    func test_remoteUsesDisplayNameInAlert() {
        let candidate = BranchDeleteCandidate.remote(branch: "feature/a", displayName: "origin/feature/a")
        XCTAssertEqual(candidate.alertTitle, "删除远端分支 origin/feature/a？")
        XCTAssertTrue(candidate.alertMessage.contains("协作者"))
    }
}

final class BranchSwitchRemotePresentationStateTests: XCTestCase {
    func test_nilRemoteBranchesYieldsEmptyResult() {
        let state = BranchSwitchRemotePresentationState(remoteBranches: nil)
        XCTAssertTrue(state.remoteBranchNames.isEmpty)
    }

    func test_keepsAllRemoteBranchesIncludingLocallyExisting() {
        let state = BranchSwitchRemotePresentationState(
            remoteBranches: ["feature/a", "feature/b", "main", "release"]
        )
        // 本地已有的不剔除(远端页签如实反映远端);顺序保持输入(排序在加载时归一)。
        XCTAssertEqual(state.remoteBranchNames, ["feature/a", "feature/b", "main", "release"])
    }

    func test_deduplicatesAndDropsBlankNames() {
        let state = BranchSwitchRemotePresentationState(
            remoteBranches: ["main", "  ", "main", ""]
        )
        XCTAssertEqual(state.remoteBranchNames, ["main"])
    }

    /// 面板统一展示裸分支名:对比模式喂进来的跟踪引用(origin/x)去掉前缀,
    /// 只切首段 remote 名,分支名自带的 "/" 必须保留。
    func test_trackingRefDisplayStripsOnlyLeadingRemoteName() {
        XCTAssertEqual(BranchRemoteRef.bareName(ofTrackingRef: "origin/feature/checkout"), "feature/checkout")
        XCTAssertEqual(BranchRemoteRef.bareName(ofTrackingRef: "origin/main"), "main")
        // 没有 "/" 的输入(如异常数据)原样返回,不能截成空串。
        XCTAssertEqual(BranchRemoteRef.bareName(ofTrackingRef: "main"), "main")
        // 只有 remote 名的畸形引用(`origin/`)也不能产出空标签。
        XCTAssertEqual(BranchRemoteRef.bareName(ofTrackingRef: "origin/"), "origin/")
    }

    /// 多 remote 仓库(fork + upstream)下两行会裸成同一个名字:必须挑出来,
    /// 让它们保留 `remote/` 前缀,否则用户无从分辨要比的是哪一个。
    func test_ambiguousBareNamesDetectsCrossRemoteCollisions() {
        XCTAssertEqual(
            BranchRemoteRef.ambiguousBareNames(ofTrackingRefs: ["origin/main", "fork/main", "origin/dev"]),
            ["main"]
        )
        XCTAssertEqual(
            BranchRemoteRef.ambiguousBareNames(ofTrackingRefs: ["origin/main", "upstream/trunk"]),
            []
        )
    }

    /// 行展示名的取舍只在"对比 + 远端页签"这一格里生效:其他页签返回 nil,
    /// 由行显示自身值(把 nil 读成"显示空"会让本地分支整列没有名字)。
    func test_displayBranchOnlyBareNamesTheCompareRemoteTab() {
        let ambiguous = BranchRemoteRef.ambiguousBareNames(ofTrackingRefs: ["origin/main", "fork/main"])

        XCTAssertEqual(
            BranchRemoteRef.displayBranch(
                ofTrackingRef: "origin/dev",
                ambiguousBareNames: ambiguous,
                showsBareRemoteNames: true
            ),
            "dev"
        )
        XCTAssertNil(
            BranchRemoteRef.displayBranch(
                ofTrackingRef: "origin/main",
                ambiguousBareNames: ambiguous,
                showsBareRemoteNames: true
            ),
            "裸名撞车时回退完整跟踪引用"
        )
        XCTAssertNil(
            BranchRemoteRef.displayBranch(
                ofTrackingRef: "main",
                ambiguousBareNames: [],
                showsBareRemoteNames: false
            )
        )
    }
}

final class BranchListNormalizationTests: XCTestCase {
    func test_sortsDedupsAndTrims() {
        let normalized = BranchListNormalization.normalized(
            [" release", "main", "feature/b", "main", "feature/a", " ", ""]
        )
        XCTAssertEqual(normalized, ["feature/a", "feature/b", "main", "release"])
    }

    func test_numericNamesUseNaturalOrdering() {
        let normalized = BranchListNormalization.normalized(
            ["release/v10", "release/v9", "release/v2"]
        )
        // localizedStandardCompare 数字感知:v10 排在 v9 之后。
        XCTAssertEqual(normalized, ["release/v2", "release/v9", "release/v10"])
    }

    func test_emptyInputYieldsEmpty() {
        XCTAssertTrue(BranchListNormalization.normalized([]).isEmpty)
    }
}

final class BranchSwitchListPresentationStateTests: XCTestCase {
    private let localBranches = ["main", "release", "feature/login"]
    /// 远端名单须为加载时归一后的形态(去重、按本地化顺序排序)。
    private let remoteBranches = ["feature/checkout", "feature/hotfix", "feature/login", "main", "release"]

    func test_localSourceFiltersLocalBranchesCaseInsensitively() {
        let state = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .local,
            searchText: "FEATURE/lo"
        )
        XCTAssertEqual(state.filteredBranches, ["feature/login"])

        let all = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .local,
            searchText: "  "
        )
        XCTAssertEqual(all.filteredBranches, localBranches)
    }

    func test_remoteSourceFiltersRemoteOnlyBranches() {
        let state = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .remote,
            searchText: "hot"
        )
        // 远端页签的行是裸分支名(面板不再展示 origin/ 前缀),且包含本地已有的分支。
        // "hot" 除子串命中 hotfix 外,还是 checkout 的子序列(h…o…t),模糊匹配一并命中。
        XCTAssertEqual(state.filteredBranches, ["feature/checkout", "feature/hotfix"])
    }

    func test_localSourceFuzzyMatchesSubsequenceQuery() {
        let state = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .local,
            searchText: "froin"
        )
        // 跳字搜索:"froin" 按序散落在 "feature/login" 中,子序列命中。
        XCTAssertEqual(state.filteredBranches, ["feature/login"])
    }

    func test_remoteSourceIncludesLocallyExistingBranches() {
        let state = BranchSwitchListPresentationState(
            localBranches: ["main", "release"],
            remoteBranchNames: ["feature/x", "main", "release"],
            source: .remote,
            searchText: ""
        )
        // 本地已有的远端分支如实列出,不再被"远端独有"过滤掉;顺序为归一后的输入顺序,
        // 展示一律裸名。
        XCTAssertEqual(state.filteredBranches, ["feature/x", "main", "release"])
    }

    func test_remoteSourceSearchMatchesWithOrWithoutOriginPrefix() {
        let bare = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .remote,
            searchText: "checkout"
        )
        let prefixed = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .remote,
            searchText: "origin/checkout"
        )
        // 行展示裸名,搜索带不带 origin/ 前缀都命中同一分支。
        XCTAssertEqual(bare.filteredBranches, prefixed.filteredBranches)
        XCTAssertEqual(prefixed.filteredBranches, ["feature/checkout"])
    }

    func test_searchNoMatchYieldsMatchEmptyText() {
        let state = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .local,
            searchText: "不存在"
        )
        XCTAssertTrue(state.filteredBranches.isEmpty)
        XCTAssertEqual(state.emptyTitle, "未找到匹配分支")
        XCTAssertEqual(state.emptySubtitle, "试试分支名中的关键词。")
    }

    func test_noCandidatesKeepsTabSpecificEmptyText() {
        let localEmpty = BranchSwitchListPresentationState(
            localBranches: [],
            remoteBranchNames: remoteBranches,
            source: .local,
            searchText: ""
        )
        XCTAssertEqual(localEmpty.emptyTitle, "暂无可切换的本地分支")
        XCTAssertEqual(localEmpty.emptySubtitle, "")

        let remoteEmpty = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: [],  // 远端没有任何分支
            source: .remote,
            searchText: ""
        )
        XCTAssertTrue(remoteEmpty.filteredBranches.isEmpty)
        XCTAssertEqual(remoteEmpty.emptyTitle, "远端没有分支")
        XCTAssertEqual(remoteEmpty.emptySubtitle, "如远端刚推送了新分支，可点击重试重新获取")

        // 搜索无匹配与"没有远端独有分支"文案不同。
        let remoteNoMatch = BranchSwitchListPresentationState(
            localBranches: localBranches,
            remoteBranchNames: remoteBranches,
            source: .remote,
            searchText: "zzz"
        )
        XCTAssertEqual(remoteNoMatch.emptyTitle, "未找到匹配分支")
    }

    func test_searchOnlyFiltersRows() {
        let branches = ["main", "release", "feature/a", "feature/b", "feature/c"]

        let filteredToOne = BranchSwitchListPresentationState(
            localBranches: branches,
            remoteBranchNames: nil,
            source: .local,
            searchText: "main"
        )

        XCTAssertEqual(filteredToOne.filteredBranches, ["main"])
    }
}
