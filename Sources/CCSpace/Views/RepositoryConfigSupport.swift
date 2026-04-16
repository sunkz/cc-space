import Foundation

struct RepositorySearchPresentationState {
    let filteredRepositories: [RepositoryConfig]
    let emptyTitle: String
    let emptySubtitle: String

    init(
        repositories: [RepositoryConfig],
        searchText: String
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearchText.isEmpty {
            filteredRepositories = repositories
            emptyTitle = "暂无仓库配置"
            emptySubtitle = ""
            return
        }

        filteredRepositories = repositories.filter { repository in
            repository.repoName.localizedCaseInsensitiveContains(trimmedSearchText)
                || repository.gitURL.localizedCaseInsensitiveContains(trimmedSearchText)
        }
        emptyTitle = "未找到匹配仓库"
        emptySubtitle = "试试仓库名称或地址中的关键词。"
    }
}

struct RepositoryAddPresentationState {
    let canSubmit: Bool

    init(gitURL: String) {
        canSubmit = !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RepositoryEditPresentationState {
    let isEditing: Bool
    let canSubmit: Bool

    init(
        repository: RepositoryConfig,
        editingRepositoryID: UUID?,
        editingGitURL: String
    ) {
        let trimmedGitURL = editingGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = editingRepositoryID == repository.id
        canSubmit =
            isEditing &&
            !trimmedGitURL.isEmpty &&
            trimmedGitURL != repository.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RepositoryDeletePresentationState: Equatable {
    let repositoryID: UUID
    let title: String
    let message: String
    let confirmLabel: String
    let isBlocked: Bool

    init(
        repository: RepositoryConfig,
        workplaces: [Workplace]
    ) {
        repositoryID = repository.id

        let referencingWorkplaceNames = workplaces
            .filter { $0.selectedRepositoryIDs.contains(repository.id) }
            .map(\.name)
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }

        if referencingWorkplaceNames.isEmpty {
            title = "删除 \(repository.repoName)"
            message = "删除后将无法在新工作区中继续选择该仓库，此操作不可撤销。"
            confirmLabel = "确认删除"
            isBlocked = false
        } else {
            title = "无法删除 \(repository.repoName)"
            message = """
            以下工作区仍在使用该仓库，请先编辑工作区移除后再删除。
            工作区：\(referencingWorkplaceNames.joined(separator: "、"))
            """
            confirmLabel = ""
            isBlocked = true
        }
    }
}

enum RepositoryConfigFeedbackFactory {
    static func addSuccess(repositoryName: String) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已新增 \(repositoryName)")
    }

    static func updateSuccess(repositoryName: String) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已更新 \(repositoryName)")
    }

    static func deleteSuccess(repositoryName: String) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已删除 \(repositoryName)")
    }
}
