import AppKit
import Foundation

struct RepositoryBranchCacheKey: Hashable {
    let workplaceID: UUID
    let repositoryID: UUID

    init(workplaceID: UUID, repositoryID: UUID) {
        self.workplaceID = workplaceID
        self.repositoryID = repositoryID
    }

    init(state: RepositorySyncState) {
        self.init(
            workplaceID: state.workplaceID,
            repositoryID: state.repositoryID
        )
    }
}

struct RepositoryBranchSnapshot: Equatable {
    let currentBranch: String?
    let branches: [String]
    let status: GitBranchStatusSnapshot?
}

enum WorkplaceBranchLoader {
    static let maxConcurrentSnapshotLoads = 4

    static func loadBranchSnapshots(
        for syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> [RepositoryBranchCacheKey: RepositoryBranchSnapshot] {
        let branchStates = syncStates.filter(\.hasLocalDirectory)
        guard branchStates.isEmpty == false else { return [:] }

        var snapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]

        await withTaskGroup(of: (RepositoryBranchCacheKey, RepositoryBranchSnapshot?).self) { group in
            let initialTaskCount = min(maxConcurrentSnapshotLoads, branchStates.count)
            var nextStateIndex = 0

            for _ in 0..<initialTaskCount {
                let state = branchStates[nextStateIndex]
                nextStateIndex += 1
                group.addTask {
                    await loadBranchSnapshot(for: state, gitService: gitService)
                }
            }

            while let (key, snapshot) = await group.next() {
                if let snapshot {
                    snapshots[key] = snapshot
                }

                guard Task.isCancelled == false else {
                    group.cancelAll()
                    continue
                }

                guard nextStateIndex < branchStates.count else { continue }
                let state = branchStates[nextStateIndex]
                nextStateIndex += 1
                group.addTask {
                    await loadBranchSnapshot(for: state, gitService: gitService)
                }
            }
        }

        return snapshots
    }

    private static func loadBranchSnapshot(
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> (RepositoryBranchCacheKey, RepositoryBranchSnapshot?) {
        let key = RepositoryBranchCacheKey(state: state)
        let localPath = state.localPath

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        let status = await gitService.branchStatus(in: localPath)

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        let currentBranch: String?
        if let statusBranch = status?.currentBranch {
            currentBranch = statusBranch
        } else {
            currentBranch = await gitService.currentBranch(in: localPath)
        }

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        let branches = await gitService.branches(in: localPath)

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        return (
            key,
            RepositoryBranchSnapshot(
                currentBranch: currentBranch,
                branches: normalizedBranches(
                    branches,
                    currentBranch: currentBranch
                ),
                status: status
            )
        )
    }
}

private func normalizedBranches(
    _ branches: [String],
    currentBranch: String?
) -> [String] {
    var normalized = branches
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if let currentBranch,
       normalized.contains(currentBranch) == false {
        normalized.append(currentBranch)
    }

    return Array(Set(normalized)).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }
}

enum WorkplaceSystemActions {
    static func openTerminal(at path: String) throws {
        let isTerminalRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
        }

        if isTerminalRunning {
            try openTerminalTab(at: path)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", path]
            try process.run()
        }
    }

    private static func openTerminalTab(at path: String) throws {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let source = """
            tell application "Terminal"
                activate
                if (count of windows) > 0 then
                    tell application "System Events" to tell process "Terminal"
                        keystroke "t" using command down
                    end tell
                    delay 0.3
                    do script "cd '\(escapedPath)'" in front window
                else
                    do script "cd '\(escapedPath)'"
                end if
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try process.run()
    }

    static func showInFinder(at path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func openInBrowser(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法打开浏览器"]
            )
        }
    }
}

struct WorkplaceDetailPresentationState {
    let isActionLocked: Bool
    let showsOperationProgress: Bool
    let canEditWorkplace: Bool
    let canSyncAllRepositories: Bool
    let canPushAllRepositories: Bool
    let canMergeDefaultBranchIntoCurrent: Bool
    let canSwitchRepositoriesToDefaultBranch: Bool
    let canSwitchRepositoriesToWorkBranch: Bool
    let canOpenDirectory: Bool
    let canDeleteWorkplace: Bool
    let editHelp: String
    let syncHelp: String
    let pushHelp: String
    let mergeDefaultBranchHelp: String
    let switchDefaultBranchHelp: String
    let switchWorkBranchHelp: String
    let deleteHelp: String

    init(
        actionState: WorkplaceActionState,
        isPerformingAction: Bool
    ) {
        let isActionLocked = isPerformingAction || actionState.isBusy
        let normalizedWorkBranch = actionState.workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasConfiguredWorkBranch = normalizedWorkBranch.isEmpty == false

        self.isActionLocked = isActionLocked
        showsOperationProgress = isActionLocked
        canEditWorkplace = !isActionLocked
        canSyncAllRepositories = actionState.hasPullableRepositories && !isActionLocked
        canPushAllRepositories = actionState.hasLocalRepositories && !isActionLocked
        canMergeDefaultBranchIntoCurrent = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToDefaultBranch = actionState.hasLocalRepositories && !isActionLocked
        canSwitchRepositoriesToWorkBranch =
            actionState.hasLocalRepositories &&
            hasConfiguredWorkBranch &&
            !isActionLocked
        canOpenDirectory = actionState.canOpenDirectory
        canDeleteWorkplace = !isActionLocked
        editHelp = isActionLocked ? "工作区操作进行中" : "编辑工作区"
        syncHelp = isActionLocked ? "工作区操作进行中" : "同步全部已克隆仓库"
        pushHelp = isActionLocked ? "工作区操作进行中" : "推送全部需要推送的仓库"
        mergeDefaultBranchHelp = isActionLocked ? "工作区操作进行中" : "将默认分支代码合并到当前分支"
        switchDefaultBranchHelp = isActionLocked ? "工作区操作进行中" : "全部切换到默认分支"
        switchWorkBranchHelp =
            isActionLocked
            ? "工作区操作进行中"
            : hasConfiguredWorkBranch
                ? "切换全部本地仓库到工作分支：\(normalizedWorkBranch)"
                : "请先配置工作分支名称"
        deleteHelp = isActionLocked ? "工作区操作进行中" : "删除工作区"
    }
}

struct WorkplaceDeleteConfirmationState: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    init(workplace: Workplace) {
        let trimmedPath = existingDirectoryPath(workplace.path)

        title = "删除 \(workplace.name)"
        confirmLabel = "确认删除"

        if let trimmedPath {
            message = """
            将删除工作区记录，并删除本地目录中的所有文件。
            目录：\(trimmedPath)
            此操作不可撤销。
            """
        } else {
            message = "将删除工作区记录，此操作不可撤销。"
        }
    }
}

struct WorkplaceRepositoryDeleteConfirmationState: Equatable {
    let title: String
    let message: String
    let confirmLabel: String

    init(
        repositoryName: String,
        localPath: String
    ) {
        let trimmedPath = existingDirectoryPath(localPath)

        title = "删除 \(repositoryName)"
        confirmLabel = "确认删除"

        if let trimmedPath {
            message = """
            将从当前工作区移除该仓库，并删除本地目录中的所有文件。
            目录：\(trimmedPath)
            此操作不可撤销。
            """
        } else {
            message = "将从当前工作区移除该仓库，此操作不可撤销。"
        }
    }
}

struct WorkplaceRepositoryBranchPillState: Equatable {
    let title: String
    let quickHelp: String
    let isDefault: Bool

    init?(
        currentBranch: String?,
        defaultBranch: String?,
        hasAvailableBranches: Bool
    ) {
        let normalizedCurrentBranch = currentBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalizedCurrentBranch.isEmpty == false else { return nil }

        let normalizedDefaultBranch = defaultBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isDefault = normalizedCurrentBranch == normalizedDefaultBranch
        title = normalizedCurrentBranch
        quickHelp = hasAvailableBranches ? "当前分支" : "当前分支，暂无可切换的本地分支"
    }
}

struct WorkplaceRepositoryRowPresentationState {
    let canRetryClone: Bool
    let canPullLatest: Bool
    let canPushToRemote: Bool
    let canOpenLocalActions: Bool
    let canDeleteRepository: Bool
    let canCreateMergeRequest: Bool
    let canSwitchBranch: Bool
    let visibleErrorMessage: String?

    init(
        syncState: RepositorySyncState,
        hasRetryRepository: Bool,
        hasPullRepository: Bool,
        allowsDeleteRepository: Bool,
        actionsDisabled: Bool
    ) {
        canRetryClone =
            syncState.status == .failed &&
            hasRetryRepository &&
            !actionsDisabled
        canPullLatest =
            syncState.status == .success &&
            hasPullRepository &&
            syncState.hasLocalDirectory &&
            !actionsDisabled
        canOpenLocalActions = syncState.hasLocalDirectory
        canPushToRemote = canOpenLocalActions && !actionsDisabled
        canDeleteRepository = allowsDeleteRepository && !actionsDisabled
        canCreateMergeRequest = canOpenLocalActions && !actionsDisabled
        canSwitchBranch = canCreateMergeRequest
        let trimmedError = syncState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleErrorMessage =
            syncState.status == .failed && !trimmedError.isEmpty
            ? trimmedError
            : nil
    }
}

enum WorkplaceDetailFeedbackFactory {
    static func actionError(action: String, error: Error) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionError(action: action, error: error)
    }

    static func retryClone(
        repositoryName: String,
        syncState: RepositorySyncState?
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.repositoryActionResult(
            repositoryName: repositoryName,
            syncState: syncState,
            successMessage: "已重新克隆 \(repositoryName)",
            fallbackFailureMessage: "重新克隆 \(repositoryName) 失败"
        )
    }

    static func syncRepository(
        repositoryName: String,
        result: RepositoryPullResult,
        syncState: RepositorySyncState?
    ) -> CCSpaceFeedback {
        if result.failedCount == 0 && result.successCount == 0 && result.skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 当前不是默认分支，已跳过同步"
            )
        }

        return CCSpaceFeedbackFactory.repositoryActionResult(
            repositoryName: repositoryName,
            syncState: syncState,
            successMessage: "已同步 \(repositoryName)",
            fallbackFailureMessage: "同步 \(repositoryName) 失败"
        )
    }

    static func pushRepository(
        repositoryName: String,
        outcome: RepositoryPushOutcome,
        syncState: RepositorySyncState?
    ) -> CCSpaceFeedback {
        switch outcome {
        case .pushed:
            return CCSpaceFeedbackFactory.repositoryActionResult(
                repositoryName: repositoryName,
                syncState: syncState,
                successMessage: "已推送 \(repositoryName)",
                fallbackFailureMessage: "推送 \(repositoryName) 失败"
            )
        case .skipped:
            return CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 没有需要推送的提交"
            )
        }
    }

    static func switchBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已切换 \(repositoryName) 到 \(branch)")
    }

    static func switchRepositoryToDefaultBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已将 \(repositoryName) 切换到默认分支 \(branch)")
    }

    static func switchRepositoryToWorkBranch(
        repositoryName: String,
        branch: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已将 \(repositoryName) 切换到工作分支 \(branch)")
    }

    static func openMergeRequest(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已打开 \(repositoryName) 的 MR 创建页")
    }

    static func deleteRepository(
        repositoryName: String
    ) -> CCSpaceFeedback {
        CCSpaceFeedbackFactory.actionSuccess("已从工作区删除 \(repositoryName)")
    }

    static func mergeRepositoryDefaultBranchIntoCurrent(
        repositoryName: String,
        outcome: GitMergeDefaultBranchOutcome
    ) -> CCSpaceFeedback {
        switch outcome {
        case .merged:
            return CCSpaceFeedbackFactory.actionSuccess("已将默认分支代码合并到 \(repositoryName)")
        case .skipped:
            return CCSpaceFeedback(
                style: .info,
                message: "\(repositoryName) 当前已在默认分支，已跳过合并"
            )
        }
    }

    static func switchAllToDefaultBranch(
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        batchSwitchBranches(
            result: result,
            successMessage: "已将 \(result.successCount) 个仓库切换到默认分支",
            mixedMessage: "切换到默认分支完成，\(result.successCount) 个成功，\(result.failedCount) 个失败",
            failureMessage: "切换到默认分支失败，\(result.failedCount) 个仓库失败"
        )
    }

    static func switchAllToWorkBranch(
        branch: String,
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        batchSwitchBranches(
            result: result,
            successMessage: "已将 \(result.successCount) 个仓库切换到工作分支 \(branch)",
            mixedMessage: "切换到工作分支 \(branch) 完成，\(result.successCount) 个成功，\(result.failedCount) 个失败",
            failureMessage: "切换到工作分支 \(branch) 失败，\(result.failedCount) 个仓库失败"
        )
    }

    static func mergeDefaultBranchIntoCurrent(
        result: WorkplaceBulkBranchSwitchResult
    ) -> CCSpaceFeedback {
        if result.failedCount > 0 && (result.successCount > 0 || result.skippedCount > 0) {
            return CCSpaceFeedback(
                style: .warning,
                message: "合并默认分支完成，\(result.successCount) 个成功，\(result.skippedCount) 个跳过，\(result.failedCount) 个失败"
            )
        }
        if result.failedCount > 0 {
            return CCSpaceFeedback(
                style: .error,
                message: "合并默认分支失败，\(result.failedCount) 个仓库失败"
            )
        }
        if result.successCount > 0 && result.skippedCount > 0 {
            return CCSpaceFeedback(
                style: .success,
                message: "合并默认分支完成，\(result.successCount) 个成功，\(result.skippedCount) 个跳过"
            )
        }
        if result.skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "已跳过 \(result.skippedCount) 个默认分支仓库"
            )
        }
        return CCSpaceFeedbackFactory.actionSuccess("已将默认分支代码合并到 \(result.successCount) 个仓库")
    }

    static func syncAll(
        result: RepositoryPullResult
    ) -> CCSpaceFeedback {
        return CCSpaceFeedbackFactory.bulkSyncSummary(
            successCount: result.successCount,
            failedCount: result.failedCount,
            skippedCount: result.skippedCount
        )
    }

    static func pushAll(
        result: RepositoryPushResult
    ) -> CCSpaceFeedback {
        if result.failedCount > 0 && result.successCount > 0 {
            return CCSpaceFeedback(
                style: .warning,
                message: bulkPushMessage(
                    successCount: result.successCount,
                    failedCount: result.failedCount,
                    skippedCount: result.skippedCount
                )
            )
        }
        if result.failedCount > 0 {
            return CCSpaceFeedback(
                style: .error,
                message: result.skippedCount > 0
                    ? "推送失败，\(result.failedCount) 个失败，\(result.skippedCount) 个跳过"
                    : "推送失败，\(result.failedCount) 个仓库失败"
            )
        }
        if result.successCount > 0 && result.skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "已推送 \(result.successCount) 个仓库，跳过 \(result.skippedCount) 个"
            )
        }
        if result.skippedCount > 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "没有需要推送的仓库"
            )
        }
        if result.successCount == 0 {
            return CCSpaceFeedback(
                style: .info,
                message: "没有可推送的仓库"
            )
        }
        return CCSpaceFeedbackFactory.actionSuccess("已推送 \(result.successCount) 个仓库")
    }

    private static func batchSwitchBranches(
        result: WorkplaceBulkBranchSwitchResult,
        successMessage: String,
        mixedMessage: String,
        failureMessage: String
    ) -> CCSpaceFeedback {
        if result.failedCount > 0 && result.successCount > 0 {
            return CCSpaceFeedback(style: .warning, message: mixedMessage)
        }
        if result.failedCount > 0 {
            return CCSpaceFeedback(style: .error, message: failureMessage)
        }
        return CCSpaceFeedbackFactory.actionSuccess(successMessage)
    }

    private static func bulkPushMessage(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int
    ) -> String {
        if skippedCount > 0 {
            return "推送完成，\(successCount) 个成功，\(failedCount) 个失败，\(skippedCount) 个跳过"
        }
        return "推送完成，\(successCount) 个成功，\(failedCount) 个失败"
    }
}

private func existingDirectoryPath(_ path: String) -> String? {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedPath.isEmpty == false else { return nil }

    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
        atPath: trimmedPath,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        return nil
    }

    return trimmedPath
}
