import XCTest
@testable import CCSpace

final class WorkplaceFormPresentationStateTests: XCTestCase {
    func test_createOptionsSortRepositoriesByName() {
        let repositories = [
            makeRepository(repoName: "web"),
            makeRepository(repoName: "api"),
        ]

        let options = WorkplaceSelectableRepositoryFactory.createOptions(
            repositories: repositories
        )

        XCTAssertEqual(options.map(\.name), ["api", "web"])
    }

    func test_editOptionsIncludeMissingConfiguredRepositoryStateOnce() {
        let missingRepositoryID = UUID()
        let existingRepository = makeRepository(repoName: "api")
        let workplace = makeWorkplace(selectedRepositoryIDs: [existingRepository.id, missingRepositoryID])
        let syncStates = [
            RepositorySyncState(
                workplaceID: workplace.id,
                repositoryID: missingRepositoryID,
                status: .success,
                localPath: "/tmp/workplaces/main/blog",
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: UUID(),
                repositoryID: UUID(),
                status: .success,
                localPath: "/tmp/workplaces/other/ignored",
                lastError: nil,
                lastSyncedAt: nil
            ),
        ]

        let options = WorkplaceSelectableRepositoryFactory.editOptions(
            workplace: workplace,
            repositories: [existingRepository],
            syncStates: syncStates
        )

        XCTAssertEqual(options.map(\.name), ["api", "blog"])
        XCTAssertEqual(options.last?.url, "/tmp/workplaces/main/blog")
    }

    func test_editOptionsAvoidDuplicateFolderNamesFromMultipleMissingStates() {
        let workplace = makeWorkplace(selectedRepositoryIDs: [])
        let syncStates = [
            RepositorySyncState(
                workplaceID: workplace.id,
                repositoryID: UUID(),
                status: .success,
                localPath: "/tmp/workplaces/main/blog",
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: workplace.id,
                repositoryID: UUID(),
                status: .success,
                localPath: "/tmp/workplaces/main/blog",
                lastError: nil,
                lastSyncedAt: nil
            ),
        ]

        let options = WorkplaceSelectableRepositoryFactory.editOptions(
            workplace: workplace,
            repositories: [],
            syncStates: syncStates
        )

        XCTAssertEqual(options.map(\.name), ["blog"])
    }

    func test_repositorySelectionStateReturnsAllRepositoriesWhenSearchIsEmpty() {
        let repositories = [
            WorkplaceSelectableRepository(id: UUID(), name: "api", url: "git@example.com:team/api.git"),
            WorkplaceSelectableRepository(id: UUID(), name: "web", url: "git@example.com:team/web.git"),
        ]

        let state = WorkplaceRepositorySelectionPresentationState(
            repositories: repositories,
            searchText: "   ",
            emptySubtitle: "请先添加仓库"
        )

        XCTAssertEqual(state.filteredRepositories, repositories)
        XCTAssertEqual(state.emptyTitle, "暂无可选仓库")
        XCTAssertEqual(state.emptySubtitle, "请先添加仓库")
    }

    func test_repositorySelectionStateFiltersRepositoriesByNameOrURL() {
        let apiRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "api",
            url: "git@example.com:team/api.git"
        )
        let webRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "web",
            url: "git@example.com:frontend/portal.git"
        )

        let nameState = WorkplaceRepositorySelectionPresentationState(
            repositories: [apiRepository, webRepository],
            searchText: "API",
            emptySubtitle: ""
        )
        let urlState = WorkplaceRepositorySelectionPresentationState(
            repositories: [apiRepository, webRepository],
            searchText: "frontend",
            emptySubtitle: ""
        )

        XCTAssertEqual(nameState.filteredRepositories, [apiRepository])
        XCTAssertEqual(urlState.filteredRepositories, [webRepository])
    }

    func test_repositorySelectionStateShowsSearchEmptyStateWhenNoRepositoryMatches() {
        let state = WorkplaceRepositorySelectionPresentationState(
            repositories: [
                WorkplaceSelectableRepository(
                    id: UUID(),
                    name: "api",
                    url: "git@example.com:team/api.git"
                )
            ],
            searchText: "mobile",
            emptySubtitle: ""
        )

        XCTAssertTrue(state.filteredRepositories.isEmpty)
        XCTAssertEqual(state.emptyTitle, "未找到匹配仓库")
        XCTAssertEqual(state.emptySubtitle, "试试仓库名称或地址中的关键词。")
    }

    func test_repositoryOrderingShowsSelectedRepositoriesFirst() {
        let apiRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "api",
            url: "git@example.com:team/api.git"
        )
        let mobileRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "mobile",
            url: "git@example.com:team/mobile.git"
        )
        let webRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "web",
            url: "git@example.com:team/web.git"
        )

        let orderedRepositories = WorkplaceSelectableRepositoryOrdering.prioritizeSelected(
            repositories: [apiRepository, mobileRepository, webRepository],
            selectedIDs: [webRepository.id, mobileRepository.id]
        )

        XCTAssertEqual(
            orderedRepositories,
            [mobileRepository, webRepository, apiRepository]
        )
    }

    func test_repositoryOrderingKeepsSelectedRepositoriesFirstAfterFiltering() {
        let apiRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "api-core",
            url: "git@example.com:team/api-core.git"
        )
        let webRepository = WorkplaceSelectableRepository(
            id: UUID(),
            name: "api-web",
            url: "git@example.com:team/api-web.git"
        )

        let filteredState = WorkplaceRepositorySelectionPresentationState(
            repositories: [apiRepository, webRepository],
            searchText: "api",
            emptySubtitle: ""
        )
        let orderedRepositories = WorkplaceSelectableRepositoryOrdering.prioritizeSelected(
            repositories: filteredState.filteredRepositories,
            selectedIDs: [webRepository.id]
        )

        XCTAssertEqual(orderedRepositories, [webRepository, apiRepository])
    }

    func test_createStateBlocksSubmitAndShowsRootPathWarningWhenRootPathMissing() {
        let presentationState = WorkplaceCreatePresentationState(
            name: "Blog",
            branch: "",
            selectedRepositoryCount: 1,
            rootPath: "",
            isSubmitting: false
        )

        XCTAssertFalse(presentationState.canSubmit)
        XCTAssertEqual(presentationState.selectedRepositorySubtitle, "1 个已选")
        XCTAssertNil(presentationState.branchStrategyFeedback)
        XCTAssertEqual(
            presentationState.missingRootPathFeedback,
            CCSpaceFeedback(style: .warning, message: "请先设置工作区根目录。")
        )
    }

    func test_createStateAllowsSubmitWhenInputsReady() {
        let presentationState = WorkplaceCreatePresentationState(
            name: "Blog",
            branch: "",
            selectedRepositoryCount: 2,
            rootPath: "/tmp/workspaces",
            isSubmitting: false
        )

        XCTAssertTrue(presentationState.canSubmit)
        XCTAssertNil(presentationState.branchStrategyFeedback)
        XCTAssertNil(presentationState.missingRootPathFeedback)
    }

    func test_createStateTrimsRootPathBeforeAllowingSubmit() {
        let presentationState = WorkplaceCreatePresentationState(
            name: "Blog",
            branch: "",
            selectedRepositoryCount: 2,
            rootPath: " /tmp/workspaces ",
            isSubmitting: false
        )

        XCTAssertTrue(presentationState.canSubmit)
        XCTAssertNil(presentationState.missingRootPathFeedback)
    }

    func test_createStateShowsBranchStrategyFeedbackWhenBranchIsFilled() {
        let presentationState = WorkplaceCreatePresentationState(
            name: "Blog",
            branch: "release/01",
            selectedRepositoryCount: 2,
            rootPath: "/tmp/workspaces",
            isSubmitting: false
        )

        XCTAssertEqual(
            presentationState.branchStrategyFeedback,
            CCSpaceFeedback(
                style: .info,
                message: "将优先使用远端同名分支；若远端不存在，则基于默认分支创建本地分支。"
            )
        )
    }

    func test_editStateBuildsSelectionSummaryAndRemovalWarning() {
        let retainedRepositoryID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let removedRepositoryID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let addedRepositoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let presentationState = WorkplaceEditPresentationState(
            originalName: "Blog",
            name: "Blog",
            originalBranch: "main",
            branch: "release/01",
            originalSelectedRepositoryIDs: [retainedRepositoryID, removedRepositoryID],
            selectedRepositoryIDs: [retainedRepositoryID, addedRepositoryID],
            isSaving: false
        )

        XCTAssertTrue(presentationState.canSubmit)
        XCTAssertEqual(presentationState.selectedRepositorySubtitle, "2 个已选")
        XCTAssertEqual(
            presentationState.removalWarningFeedback,
            CCSpaceFeedback(style: .warning, message: "取消勾选后，如本地目录已存在，将一并删除对应本地文件。")
        )
        XCTAssertEqual(
            presentationState.changeSummaryFeedback,
            CCSpaceFeedback(style: .info, message: "将新增 1 个仓库，移除 1 个仓库，工作分支改为 release/01")
        )
        XCTAssertEqual(
            presentationState.branchChangeFeedback,
            CCSpaceFeedback(
                style: .info,
                message: "保存后会切换已保留的本地仓库到 release/01，已在目标分支上的仓库会自动跳过。"
            )
        )
    }

    func test_editStateBlocksSubmitWhenNameOrSelectionInvalid() {
        let emptyNameState = WorkplaceEditPresentationState(
            originalName: "Blog",
            name: "   ",
            originalBranch: nil,
            branch: "",
            originalSelectedRepositoryIDs: [UUID()],
            selectedRepositoryIDs: [UUID()],
            isSaving: false
        )
        let noSelectionState = WorkplaceEditPresentationState(
            originalName: "Blog",
            name: "Blog",
            originalBranch: nil,
            branch: "",
            originalSelectedRepositoryIDs: [UUID()],
            selectedRepositoryIDs: [],
            isSaving: false
        )

        XCTAssertFalse(emptyNameState.canSubmit)
        XCTAssertFalse(noSelectionState.canSubmit)
        XCTAssertEqual(noSelectionState.selectedRepositorySubtitle, "")
        XCTAssertEqual(
            noSelectionState.removalWarningFeedback,
            CCSpaceFeedback(style: .warning, message: "取消勾选后，如本地目录已存在，将一并删除对应本地文件。")
        )
        XCTAssertEqual(
            noSelectionState.changeSummaryFeedback,
            CCSpaceFeedback(style: .info, message: "将移除 1 个仓库")
        )
    }

    func test_editStateBlocksSubmitWhenNothingChanged() {
        let repositoryID = UUID()
        let presentationState = WorkplaceEditPresentationState(
            originalName: "Blog",
            name: " Blog ",
            originalBranch: "release/01",
            branch: " release/01 ",
            originalSelectedRepositoryIDs: [repositoryID],
            selectedRepositoryIDs: [repositoryID],
            isSaving: false
        )

        XCTAssertFalse(presentationState.canSubmit)
        XCTAssertEqual(presentationState.selectedRepositorySubtitle, "1 个已选")
        XCTAssertNil(presentationState.changeSummaryFeedback)
        XCTAssertNil(presentationState.branchChangeFeedback)
    }

    func test_editStateWarnsWhenClearingConfiguredBranch() {
        let repositoryID = UUID()
        let presentationState = WorkplaceEditPresentationState(
            originalName: "Blog",
            name: "Blog",
            originalBranch: "release/01",
            branch: "   ",
            originalSelectedRepositoryIDs: [repositoryID],
            selectedRepositoryIDs: [repositoryID],
            isSaving: false
        )

        XCTAssertTrue(presentationState.canSubmit)
        XCTAssertEqual(
            presentationState.changeSummaryFeedback,
            CCSpaceFeedback(style: .info, message: "将清空工作分支")
        )
        XCTAssertEqual(
            presentationState.branchChangeFeedback,
            CCSpaceFeedback(style: .warning, message: "清空后将移除工作分支配置，不会自动切换现有仓库。")
        )
    }

    private func makeRepository(
        repoName: String,
        id: UUID = UUID()
    ) -> RepositoryConfig {
        RepositoryConfig(
            id: id,
            gitURL: "https://example.com/\(repoName).git",
            repoName: repoName,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeWorkplace(
        selectedRepositoryIDs: [UUID],
        id: UUID = UUID()
    ) -> Workplace {
        Workplace(
            id: id,
            name: "Main",
            path: "/tmp/workplaces/main",
            selectedRepositoryIDs: selectedRepositoryIDs,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
