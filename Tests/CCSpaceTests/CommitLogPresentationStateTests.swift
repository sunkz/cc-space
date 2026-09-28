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

    func test_emptySearchReturnsAllCommits() {
        let state = CommitLogPresentationState(
            commits: makeCommits(),
            searchText: "   ",
            scope: .all,
            hasUpstream: true
        )

        XCTAssertEqual(state.filteredCommits.count, 2)
        XCTAssertEqual(state.countLabel, "2 条提交")
        XCTAssertEqual(state.emptyTitle, "未找到匹配提交")
    }

    func test_searchMatchesSubjectAuthorAndHashCaseInsensitively() {
        let commits = makeCommits()

        let bySubject = CommitLogPresentationState(
            commits: commits, searchText: "登录", scope: .all, hasUpstream: true
        )
        XCTAssertEqual(bySubject.filteredCommits.map(\.hash), ["aaaaaa1111111111"])

        let byAuthor = CommitLogPresentationState(
            commits: commits, searchText: "alice", scope: .all, hasUpstream: true
        )
        XCTAssertEqual(byAuthor.filteredCommits.map(\.hash), ["bbbbbb2222222222"])

        // hash 前缀(不区分大小写)也可命中。
        let byHash = CommitLogPresentationState(
            commits: commits, searchText: "AAAAAA", scope: .all, hasUpstream: true
        )
        XCTAssertEqual(byHash.filteredCommits.map(\.hash), ["aaaaaa1111111111"])

        let noMatch = CommitLogPresentationState(
            commits: commits, searchText: "不存在", scope: .all, hasUpstream: true
        )
        XCTAssertTrue(noMatch.filteredCommits.isEmpty)
        XCTAssertEqual(noMatch.emptyTitle, "未找到匹配提交")
        XCTAssertEqual(noMatch.emptySubtitle, "试试提交说明、作者或 commit ID 中的关键词。")
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
        XCTAssertTrue(empty.filteredCommits.isEmpty)
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

    func test_displayNameAddsOriginPrefixAndBranchNameStripsIt() {
        let state = BranchSwitchRemotePresentationState(remoteBranches: ["feature"])

        XCTAssertEqual(state.displayName(for: "feature"), "origin/feature")
        XCTAssertEqual(state.branchName(fromDisplayName: "origin/feature"), "feature")
        // 非远端展示名原样返回(本地页签共用同一条还原路径)。
        XCTAssertEqual(state.branchName(fromDisplayName: "main"), "main")
    }
}

final class BranchListNormalizationTests: XCTestCase {
    func test_sortsDedupsAndTrims() {
        let normalized = BranchListNormalization.remoteBranches(
            [" release", "main", "feature/b", "main", "feature/a", " ", ""]
        )
        XCTAssertEqual(normalized, ["feature/a", "feature/b", "main", "release"])
    }

    func test_numericNamesUseNaturalOrdering() {
        let normalized = BranchListNormalization.remoteBranches(
            ["release/v10", "release/v9", "release/v2"]
        )
        // localizedStandardCompare 数字感知:v10 排在 v9 之后。
        XCTAssertEqual(normalized, ["release/v2", "release/v9", "release/v10"])
    }

    func test_emptyInputYieldsEmpty() {
        XCTAssertTrue(BranchListNormalization.remoteBranches([]).isEmpty)
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
        // 远端页签的行是 origin/ 前缀展示名,且包含本地已有的分支。
        // "hot" 除子串命中 hotfix 外,还是 checkout 的子序列(h…o…t),模糊匹配一并命中。
        XCTAssertEqual(state.filteredBranches, ["origin/feature/checkout", "origin/feature/hotfix"])
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
        // 本地已有的远端分支如实列出,不再被"远端独有"过滤掉;顺序为归一后的输入顺序。
        XCTAssertEqual(state.filteredBranches, ["origin/feature/x", "origin/main", "origin/release"])
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
        // 搜索按展示名匹配:带不带 origin/ 前缀都能命中同一分支。
        XCTAssertEqual(bare.filteredBranches, prefixed.filteredBranches)
        XCTAssertEqual(prefixed.filteredBranches, ["origin/feature/checkout"])
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

    func test_listHeightIsFixedRegardlessOfBranchCount() {
        func height(localCount: Int, remoteCount: Int?) -> CGFloat {
            let branches = (0..<localCount).map { "branch/\($0)" }
            let remote: [String]? = remoteCount.map { count in (0..<count).map { "remote/\($0)" } }
            return BranchSwitchListPresentationState(
                localBranches: branches,
                remoteBranchNames: remote,
                source: .local,
                searchText: ""
            ).listHeight
        }

        // 宽高全固定:0 条、5 条、100 条,远端未加载/已加载,高度恒为固定值。
        let fixed = BranchSwitchListPresentationState.fixedListHeight
        XCTAssertEqual(height(localCount: 0, remoteCount: nil), fixed)
        XCTAssertEqual(height(localCount: 5, remoteCount: nil), fixed)
        XCTAssertEqual(height(localCount: 100, remoteCount: nil), fixed)
        XCTAssertEqual(height(localCount: 2, remoteCount: 200), fixed)
    }

    func test_listHeightIgnoresSearchFilter() {
        let branches = ["main", "release", "feature/a", "feature/b", "feature/c"]

        let unfiltered = BranchSwitchListPresentationState(
            localBranches: branches,
            remoteBranchNames: nil,
            source: .local,
            searchText: ""
        )
        let filteredToOne = BranchSwitchListPresentationState(
            localBranches: branches,
            remoteBranchNames: nil,
            source: .local,
            searchText: "main"
        )
        let noMatch = BranchSwitchListPresentationState(
            localBranches: branches,
            remoteBranchNames: nil,
            source: .local,
            searchText: "zzz"
        )

        // 搜索只过滤行,高度固定,输入时不跳动。
        XCTAssertEqual(filteredToOne.filteredBranches, ["main"])
        XCTAssertEqual(unfiltered.listHeight, filteredToOne.listHeight)
        XCTAssertEqual(unfiltered.listHeight, noMatch.listHeight)
    }

    func test_listHeightStableAcrossTabSwitch() {
        let manyRemote = (0..<6).map { "feature/\($0)" }
        let fewLocal = ["main", "release"]

        let localState = BranchSwitchListPresentationState(
            localBranches: fewLocal,
            remoteBranchNames: fewLocal + manyRemote,
            source: .local,
            searchText: ""
        )
        let remoteState = BranchSwitchListPresentationState(
            localBranches: fewLocal,
            remoteBranchNames: fewLocal + manyRemote,
            source: .remote,
            searchText: ""
        )

        // 本地 2 条、远端 8 条:两页签同高(固定值),切换页签不跳动,本地页签底部留白。
        XCTAssertEqual(localState.listHeight, BranchSwitchListPresentationState.fixedListHeight)
        XCTAssertEqual(localState.listHeight, remoteState.listHeight)
    }
}
