import CoreGraphics
import Foundation

/// 设置页仓库列表的布局参数。
enum RepositoryListLayout {
    /// 行间距。
    static let rowSpacing: CGFloat = 6
}

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
    /// 非空输入是否通过 URL 格式预检(协议白名单/选项注入防护,与 GitURLParser 同一口径)。
    /// 不并入 canSubmit:禁用按钮而无解释更糟;用于输入框下即时行内提示,
    /// 免得用户等到提交才看到 store 抛出的错误。
    let isURLFormatValid: Bool

    init(gitURL: String) {
        let trimmed = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        canSubmit = !trimmed.isEmpty
        isURLFormatValid = trimmed.isEmpty ? true : (try? GitURLParser.validateRemoteURL(trimmed)) != nil
    }
}

struct RepositoryEditPresentationState {
    let isEditing: Bool
    let isPendingNew: Bool
    let canSubmit: Bool

    init(
        repository: RepositoryConfig,
        editingRepositoryID: UUID?,
        editingGitURL: String,
        editingMRBranches: [String] = [],
        isPendingNew: Bool = false,
        isFetchingDefaultBranch: Bool = false
    ) {
        let trimmedGitURL = editingGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = editingRepositoryID == repository.id
        self.isPendingNew = isPendingNew
        let gitURLChanged = trimmedGitURL != repository.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mrBranchesChanged = editingMRBranches != repository.mrTargetBranches
        if isPendingNew {
            canSubmit = isEditing && !trimmedGitURL.isEmpty && !isFetchingDefaultBranch
        } else {
            canSubmit =
                isEditing &&
                !trimmedGitURL.isEmpty &&
                (gitURLChanged || mrBranchesChanged)
        }
    }
}

enum RepositoryBackupExportPresentationState {
    static func defaultFileName(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ccspace-git-repositories-\(formatter.string(from: now)).json"
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

struct MRTargetBranchAddPresentationState {
    let canSubmit: Bool
    let trimmedBranchName: String

    init(inputText: String, existingBranches: [String]) {
        trimmedBranchName = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        canSubmit = !trimmedBranchName.isEmpty && !existingBranches.contains(trimmedBranchName)
    }
}

/// MR 目标分支建议名单的排序:归一(去空白/去重/本地化标准排序)后把默认分支提到首位。
/// localizedStandardCompare 上千分支代价可观——必须在取数任务(后台)里做一次,
/// 主线程只消费结果,与 `BranchListNormalization` 的既有约定一致。
enum RepositoryBranchSuggestionOrder {
    static func ordered(branches: [String], defaultBranch: String?) -> [String] {
        let sorted = BranchListNormalization.remoteBranches(branches)
        guard let defaultBranch,
              let defaultIndex = sorted.firstIndex(of: defaultBranch) else {
            return sorted
        }
        var result = sorted
        result.remove(at: defaultIndex)
        result.insert(defaultBranch, at: 0)
        return result
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

    static func exportSuccess(repositoryCount: Int) -> CCSpaceFeedback {
        if repositoryCount == 0 {
            return CCSpaceFeedback(style: .info, message: "已导出空备份文件")
        }
        return CCSpaceFeedbackFactory.actionSuccess("已导出 \(repositoryCount) 个仓库的备份")
    }

    static func importResult(_ result: RepositoryImportResult) -> CCSpaceFeedback {
        var parts: [String] = []
        if result.importedCount > 0 {
            parts.append("导入 \(result.importedCount) 个仓库")
        }
        if result.mergedCount > 0 {
            parts.append("合并 \(result.mergedCount) 个仓库的 MR 目标分支")
        }
        if result.skippedCount > 0 {
            parts.append("跳过 \(result.skippedCount) 个重复项")
        }

        if parts.isEmpty {
            return CCSpaceFeedback(style: .info, message: "未导入任何仓库")
        }

        let message = "已" + parts.joined(separator: "，")
        let style: CCSpaceFeedbackStyle = (result.importedCount > 0 || result.mergedCount > 0) ? .success : .info
        return CCSpaceFeedback(style: style, message: message)
    }
}
