import Foundation

enum WorkplaceFormTextNormalization {
    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedOptionalText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmedText = normalizedText(text)
        return trimmedText.isEmpty ? nil : trimmedText
    }
}

struct WorkplaceSelectableRepository: Identifiable, Equatable {
    let id: UUID
    let name: String
    let url: String
}

enum WorkplaceSelectableRepositoryOrdering {
    static func prioritizeSelected(
        repositories: [WorkplaceSelectableRepository],
        selectedIDs: Set<UUID>
    ) -> [WorkplaceSelectableRepository] {
        repositories.sorted { lhs, rhs in
            let lhsSelected = selectedIDs.contains(lhs.id)
            let rhsSelected = selectedIDs.contains(rhs.id)

            if lhsSelected != rhsSelected {
                return lhsSelected
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            let urlOrder = lhs.url.localizedStandardCompare(rhs.url)
            if urlOrder != .orderedSame {
                return urlOrder == .orderedAscending
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct WorkplaceRepositorySelectionPresentationState {
    let filteredRepositories: [WorkplaceSelectableRepository]
    let emptyTitle: String
    let emptySubtitle: String

    init(
        repositories: [WorkplaceSelectableRepository],
        searchText: String,
        emptySubtitle fallbackEmptySubtitle: String
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearchText.isEmpty {
            filteredRepositories = repositories
            emptyTitle = "暂无可选仓库"
            emptySubtitle = fallbackEmptySubtitle
            return
        }

        filteredRepositories = repositories.filter { repository in
            repository.name.localizedCaseInsensitiveContains(trimmedSearchText)
                || repository.url.localizedCaseInsensitiveContains(trimmedSearchText)
        }
        emptyTitle = "未找到匹配仓库"
        emptySubtitle = "试试仓库名称或地址中的关键词。"
    }
}

enum WorkplaceSelectableRepositoryFactory {
    static func createOptions(
        repositories: [RepositoryConfig]
    ) -> [WorkplaceSelectableRepository] {
        repositories
            .map { repository in
                WorkplaceSelectableRepository(
                    id: repository.id,
                    name: repository.repoName,
                    url: repository.gitURL
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func editOptions(
        workplace: Workplace,
        repositories: [RepositoryConfig],
        syncStates: [RepositorySyncState]
    ) -> [WorkplaceSelectableRepository] {
        var options = createOptions(repositories: repositories)
        var existingNames = Set(options.map(\.name))
        let configIDs = Set(repositories.map(\.id))
        let workplaceStates = syncStates.filter { $0.workplaceID == workplace.id }

        for state in workplaceStates where !configIDs.contains(state.repositoryID) {
            let folderName = URL(fileURLWithPath: state.localPath).lastPathComponent
            guard !existingNames.contains(folderName) else { continue }
            options.append(
                WorkplaceSelectableRepository(
                    id: state.repositoryID,
                    name: folderName,
                    url: state.localPath
                )
            )
            existingNames.insert(folderName)
        }

        return options.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct WorkplaceCreatePresentationState {
    let canSubmit: Bool
    let selectedRepositorySubtitle: String
    let branchStrategyFeedback: CCSpaceFeedback?
    let missingRootPathFeedback: CCSpaceFeedback?

    init(
        name: String,
        branch: String,
        selectedRepositoryCount: Int,
        rootPath: String,
        isSubmitting: Bool
    ) {
        let trimmedName = WorkplaceFormTextNormalization.normalizedText(name)
        let trimmedBranch = WorkplaceFormTextNormalization.normalizedText(branch)
        let trimmedRootPath = WorkplaceFormTextNormalization.normalizedText(rootPath)
        canSubmit =
            !isSubmitting &&
            !trimmedName.isEmpty &&
            selectedRepositoryCount > 0 &&
            !trimmedRootPath.isEmpty
        selectedRepositorySubtitle = selectedRepositoryCount == 0 ? "" : "\(selectedRepositoryCount) 个已选"
        branchStrategyFeedback =
            trimmedBranch.isEmpty
            ? nil
            : CCSpaceFeedback(
                style: .info,
                message: "将优先使用远端同名分支；若远端不存在，则基于默认分支创建本地分支。"
            )
        missingRootPathFeedback =
            trimmedRootPath.isEmpty
            ? CCSpaceFeedback(style: .warning, message: "请先设置工作区根目录。")
            : nil
    }
}

struct WorkplaceEditPresentationState {
    let canSubmit: Bool
    let selectedRepositorySubtitle: String
    let removalWarningFeedback: CCSpaceFeedback?
    let changeSummaryFeedback: CCSpaceFeedback?
    let branchChangeFeedback: CCSpaceFeedback?

    init(
        originalName: String,
        name: String,
        originalBranch: String?,
        branch: String,
        originalSelectedRepositoryIDs: [UUID],
        selectedRepositoryIDs: Set<UUID>,
        isSaving: Bool
    ) {
        let trimmedName = WorkplaceFormTextNormalization.normalizedText(name)
        let trimmedOriginalName = WorkplaceFormTextNormalization.normalizedText(originalName)
        let normalizedBranch = WorkplaceFormTextNormalization.normalizedOptionalText(branch)
        let normalizedOriginalBranch = WorkplaceFormTextNormalization.normalizedOptionalText(originalBranch)
        let originalSelectedSet = Set(originalSelectedRepositoryIDs)
        let addedCount = selectedRepositoryIDs.subtracting(originalSelectedSet).count
        let removedCount = originalSelectedSet.subtracting(selectedRepositoryIDs).count
        let nameChanged = trimmedName != trimmedOriginalName
        let branchChanged = normalizedBranch != normalizedOriginalBranch
        let hasChanges = nameChanged || addedCount > 0 || removedCount > 0 || branchChanged

        canSubmit =
            !isSaving &&
            !trimmedName.isEmpty &&
            selectedRepositoryIDs.isEmpty == false &&
            hasChanges
        selectedRepositorySubtitle = selectedRepositoryIDs.isEmpty ? "" : "\(selectedRepositoryIDs.count) 个已选"
        removalWarningFeedback =
            removedCount > 0
            ? CCSpaceFeedback(style: .warning, message: "取消勾选后，如本地目录已存在，将一并删除对应本地文件。")
            : nil

        var changeSegments: [String] = []
        if nameChanged, trimmedName.isEmpty == false {
            changeSegments.append("重命名为 \(trimmedName)")
        }
        if addedCount > 0 {
            changeSegments.append("新增 \(addedCount) 个仓库")
        }
        if removedCount > 0 {
            changeSegments.append("移除 \(removedCount) 个仓库")
        }
        if branchChanged {
            if let normalizedBranch {
                changeSegments.append("工作分支改为 \(normalizedBranch)")
            } else {
                changeSegments.append("清空工作分支")
            }
        }
        changeSummaryFeedback =
            changeSegments.isEmpty
            ? nil
            : CCSpaceFeedback(
                style: .info,
                message: "将" + changeSegments.joined(separator: "，")
            )

        if branchChanged, let normalizedBranch {
            branchChangeFeedback = CCSpaceFeedback(
                style: .info,
                message: "保存后会切换已保留的本地仓库到 \(normalizedBranch)，已在目标分支上的仓库会自动跳过。"
            )
        } else if branchChanged, normalizedOriginalBranch != nil {
            branchChangeFeedback = CCSpaceFeedback(
                style: .warning,
                message: "清空后将移除工作分支配置，不会自动切换现有仓库。"
            )
        } else {
            branchChangeFeedback = nil
        }
    }
}
