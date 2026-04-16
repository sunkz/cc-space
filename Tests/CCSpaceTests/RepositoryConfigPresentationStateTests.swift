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
        XCTAssertEqual(state.emptySubtitle, "")
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

    func test_addStateTrimsWhitespaceBeforeAllowingSubmit() {
        XCTAssertFalse(RepositoryAddPresentationState(gitURL: "   ").canSubmit)
        XCTAssertTrue(RepositoryAddPresentationState(gitURL: " git@github.com:org/blog.git ").canSubmit)
    }

    func test_editStateOnlySubmitsWhenEditingAndURLActuallyChanges() {
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/blog.git",
            repoName: "blog",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let editingState = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: " git@gitlab.example.com:team/blog.git "
        )
        let unchangedState = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: repository.id,
            editingGitURL: " git@github.com:org/blog.git "
        )
        let nonEditingState = RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: UUID(),
            editingGitURL: "git@gitlab.example.com:team/blog.git"
        )

        XCTAssertTrue(editingState.isEditing)
        XCTAssertTrue(editingState.canSubmit)
        XCTAssertTrue(unchangedState.isEditing)
        XCTAssertFalse(unchangedState.canSubmit)
        XCTAssertFalse(nonEditingState.isEditing)
        XCTAssertFalse(nonEditingState.canSubmit)
    }

    func test_feedbackFactoryBuildsRepositorySuccessMessages() {
        XCTAssertEqual(
            RepositoryConfigFeedbackFactory.addSuccess(repositoryName: "blog"),
            CCSpaceFeedback(style: .success, message: "已新增 blog")
        )
        XCTAssertEqual(
            RepositoryConfigFeedbackFactory.updateSuccess(repositoryName: "blog"),
            CCSpaceFeedback(style: .success, message: "已更新 blog")
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
