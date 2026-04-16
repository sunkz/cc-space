import Foundation
import os

private let workplaceRuntimeLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceRuntimeService"
)

enum WorkplaceRuntimeServiceError: LocalizedError {
    case missingLocalRepository
    case emptyBranch
    case noLocalRepositories
    case missingRemoteRepository
    case missingDefaultBranch
    case unreadableGitStatus

    var errorDescription: String? {
        switch self {
        case .missingLocalRepository:
            return "仓库本地目录不存在"
        case .emptyBranch:
            return "分支名不能为空"
        case .noLocalRepositories:
            return "当前工作区没有已克隆的本地仓库"
        case .missingRemoteRepository:
            return "仓库未配置 origin 远端"
        case .missingDefaultBranch:
            return "无法识别仓库默认分支"
        case .unreadableGitStatus:
            return "无法读取仓库 Git 状态"
        }
    }
}

enum WorkplaceDeletionError: LocalizedError, Equatable {
    case unmanagedPath(workplacePath: String, rootPath: String)
    case directoryBusy(path: String)
    case permissionDenied(path: String)
    case removalFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unmanagedPath(let workplacePath, let rootPath):
            return """
            当前工作区目录不在已配置的根目录内，删除按钮默认会连同本地目录一起删除，因此被安全拦截。
            根目录：\(rootPath)
            工作区目录：\(workplacePath)
            """
        case .directoryBusy(let path):
            return """
            工作区目录正在被其他程序使用，请关闭占用该目录的终端、IDE 或本地服务后重试。
            目录：\(path)
            """
        case .permissionDenied(let path):
            return """
            没有权限删除工作区目录，请检查目录权限后重试。
            目录：\(path)
            """
        case .removalFailed(let path, let reason):
            return """
            无法删除工作区目录。
            目录：\(path)
            原因：\(reason)
            """
        }
    }

    static func fromRemovalError(
        _ error: Error,
        path: String
    ) -> WorkplaceDeletionError {
        let relevantErrors = [error as NSError] + (error as NSError).underlyingErrors

        if relevantErrors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == EBUSY }) {
            return .directoryBusy(path: path)
        }

        if relevantErrors.contains(where: {
            ($0.domain == NSPOSIXErrorDomain && ($0.code == EACCES || $0.code == EPERM)) ||
                ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteNoPermission.rawValue)
        }) {
            return .permissionDenied(path: path)
        }

        return .removalFailed(
            path: path,
            reason: error.localizedDescription
        )
    }
}

struct WorkplaceBulkBranchSwitchResult: Equatable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int

    init(successCount: Int, failedCount: Int, skippedCount: Int = 0) {
        self.successCount = successCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
    }

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

struct RepositoryPushResult: Equatable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

enum RepositoryPushOutcome: Equatable {
    case pushed
    case skipped
}

private enum BatchPushOperationResult: Sendable {
    case pushed(RepositorySyncState)
    case skipped(RepositorySyncState)
    case failed(RepositorySyncState)
}

private enum BatchBranchSwitchOperationResult: Sendable {
    case success(RepositorySyncState)
    case failed(RepositorySyncState)
}

private enum BatchBranchResolutionResult: Sendable {
    case success(String)
    case failure(String)
}

private enum BatchMergeOperationResult: Sendable {
    case merged(RepositorySyncState)
    case skipped(RepositorySyncState)
    case failed(RepositorySyncState)
}

@MainActor
struct WorkplaceRuntimeService {
    nonisolated private static let maxConcurrentBatchTasks = 4

    let workplaceStore: WorkplaceStore
    let syncCoordinator: SyncCoordinator
    let workplaceRootPath: String

    init(
        workplaceStore: WorkplaceStore,
        syncCoordinator: SyncCoordinator,
        workplaceRootPath: String = ""
    ) {
        self.workplaceStore = workplaceStore
        self.syncCoordinator = syncCoordinator
        self.workplaceRootPath = workplaceRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pullRepositories(in workplace: Workplace, repositoryID: UUID? = nil) async -> RepositoryPullResult {
        guard isManagedWorkplace(workplace) else {
            return RepositoryPullResult(successCount: 0, failedCount: 0, skippedCount: 0)
        }

        let targetStates = managedStates(
            in: workplace,
            repositoryID: repositoryID,
            requiresLocalDirectory: true
        )
        return await syncCoordinator.pullRepositories(
            syncStates: targetStates,
            workplaceStore: workplaceStore
        )
    }

    func retryClone(repository: RepositoryConfig, in workplace: Workplace) async throws {
        try ensureManagedWorkplace(workplace)
        let localPath = try WorkplaceStore.repositoryPath(
            workplacePath: workplace.path,
            repositoryName: repository.repoName
        )

        try syncCoordinator.fileSystemService.removeItemIfExists(at: localPath)

        let retriedStates = try await syncCoordinator.cloneRepositories(
            repositories: [repository],
            workplace: workplace
        )
        let untouchedStates = workplaceStore.syncStates.filter {
            $0.workplaceID == workplace.id && $0.repositoryID != repository.id
        }
        try workplaceStore.replaceSyncStates(untouchedStates + retriedStates, for: workplace.id)
    }

    func pushRepositories(in workplace: Workplace) async throws -> RepositoryPushResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        let results: [BatchPushOperationResult] = await runConcurrentStateOperations(states) { state in
            do {
                guard try await Self.shouldPushRepository(state, gitService: gitService) else {
                    return .skipped(Self.normalizedSkippedPushState(from: state))
                }

                try await gitService.push(in: state.localPath)
                return .pushed(Self.succeededState(from: state, touchLastSyncedAt: true))
            } catch {
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        try? workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let successCount = results.filter { $0.isPushed }.count
        let failedCount = results.filter { $0.isFailed }.count
        let skippedCount = results.filter { $0.isSkipped }.count

        return RepositoryPushResult(
            successCount: successCount,
            failedCount: failedCount,
            skippedCount: skippedCount
        )
    }

    func pushRepository(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> RepositoryPushOutcome {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        do {
            guard try await Self.shouldPushRepository(state, gitService: gitService) else {
                try normalizeSkippedPushState(state)
                return .skipped
            }

            try await gitService.push(in: state.localPath)
            var updatedState = state
            updatedState.status = .success
            updatedState.lastSyncedAt = .now
            updatedState.lastError = nil
            try workplaceStore.updateSyncState(updatedState)
            return .pushed
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            try? workplaceStore.updateSyncState(updatedState)
            throw error
        }
    }

    func switchBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        to branch: String
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService

        do {
            if await Self.isCurrentBranch(trimmedBranch, for: state, gitService: gitService) {
                var updatedState = state
                updatedState.status = .success
                updatedState.lastError = nil
                try workplaceStore.updateSyncState(updatedState)
                return
            }

            try await GitWorktreeSafety.validateCleanWorkingTree(
                in: state.localPath,
                gitService: gitService,
                blockedOperation: .switchBranch
            )
            try await gitService.checkoutBranch(trimmedBranch, in: state.localPath)
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            try workplaceStore.updateSyncState(updatedState)
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            try? workplaceStore.updateSyncState(updatedState)
            throw error
        }
    }

    func switchRepositoryToWorkBranch(
        for state: RepositorySyncState,
        in workplace: Workplace,
        workBranch: String
    ) async throws -> String {
        let trimmedBranch = workBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }

        try await switchBranch(for: state, in: workplace, to: trimmedBranch)
        return trimmedBranch
    }

    func switchRepositoryToDefaultBranch(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> String {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService
        guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
            throw WorkplaceRuntimeServiceError.missingDefaultBranch
        }

        try await switchBranch(for: state, in: workplace, to: defaultBranch)
        return defaultBranch
    }

    func switchRepositoriesToWorkBranch(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let trimmedBranch = workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedBranch.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.emptyBranch
        }

        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        return await switchRepositories(states) { _ in
            .success(trimmedBranch)
        }
    }

    func switchRepositoriesToDefaultBranch(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        return await switchRepositories(states) { state in
            guard let branch = await gitService.defaultBranch(in: state.localPath) else {
                return .failure(WorkplaceRuntimeServiceError.missingDefaultBranch.localizedDescription)
            }
            return .success(branch)
        }
    }

    func mergeDefaultBranchIntoCurrent(
        in workplace: Workplace
    ) async throws -> WorkplaceBulkBranchSwitchResult {
        try ensureManagedWorkplace(workplace)
        let states = switchableStates(in: workplace)
        guard states.isEmpty == false else {
            throw WorkplaceRuntimeServiceError.noLocalRepositories
        }

        let gitService = syncCoordinator.gitService
        let results: [BatchMergeOperationResult] = await runConcurrentStateOperations(states) { state in
            do {
                if await Self.shouldSkipMergeDefaultBranch(for: state, gitService: gitService) {
                    return .skipped(Self.succeededState(from: state))
                }

                try await GitWorktreeSafety.validateCleanWorkingTree(
                    in: state.localPath,
                    gitService: gitService,
                    blockedOperation: .mergeDefaultBranchIntoCurrent
                )
                let outcome = try await gitService.mergeDefaultBranchIntoCurrent(in: state.localPath)
                switch outcome {
                case .merged:
                    return .merged(Self.succeededState(from: state))
                case .skipped:
                    return .skipped(Self.succeededState(from: state))
                }
            } catch {
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        try? workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let successCount = results.filter { $0.isMerged }.count
        let failedCount = results.filter { $0.isFailed }.count
        let skippedCount = results.filter { $0.isSkipped }.count

        return WorkplaceBulkBranchSwitchResult(
            successCount: successCount,
            failedCount: failedCount,
            skippedCount: skippedCount
        )
    }

    func mergeDefaultBranchIntoCurrent(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) async throws -> GitMergeDefaultBranchOutcome {
        try ensureManagedLocalRepositoryExists(for: state, in: workplace)

        let gitService = syncCoordinator.gitService

        do {
            if await Self.shouldSkipMergeDefaultBranch(for: state, gitService: gitService) {
                var updatedState = state
                updatedState.status = .success
                updatedState.lastError = nil
                try workplaceStore.updateSyncState(updatedState)
                return .skipped
            }

            try await GitWorktreeSafety.validateCleanWorkingTree(
                in: state.localPath,
                gitService: gitService,
                blockedOperation: .mergeDefaultBranchIntoCurrent
            )

            let outcome = try await gitService.mergeDefaultBranchIntoCurrent(in: state.localPath)
            var updatedState = state
            updatedState.status = .success
            updatedState.lastError = nil
            try workplaceStore.updateSyncState(updatedState)
            return outcome
        } catch {
            var updatedState = state
            updatedState.status = .failed
            updatedState.lastError = error.localizedDescription
            try? workplaceStore.updateSyncState(updatedState)
            throw error
        }
    }

    func deleteWorkplace(_ workplace: Workplace, removeLocalDirectories: Bool) async throws {
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplace.id }

        if removeLocalDirectories {
            do {
                try ensureManagedWorkplace(workplace)
            } catch {
                let deleteError = WorkplaceDeletionError.unmanagedPath(
                    workplacePath: workplace.path,
                    rootPath: workplaceRootPath
                )
                workplaceRuntimeLog.error(
                    "event=delete_workplace_blocked root_path=\(self.workplaceRootPath, privacy: .public) workplace_path=\(workplace.path, privacy: .public)"
                )
                throw deleteError
            }
            let repoIDs = Set(originalStates.map(\.repositoryID))
            try workplaceStore.setSyncStatus(.removing, for: workplace.id, repositoryIDs: repoIDs)

            do {
                try syncCoordinator.fileSystemService.removeItemIfExists(at: workplace.path)
            } catch {
                try? workplaceStore.replaceSyncStates(originalStates, for: workplace.id)
                let deleteError = WorkplaceDeletionError.fromRemovalError(
                    error,
                    path: workplace.path
                )
                workplaceRuntimeLog.error(
                    "event=delete_workplace_remove_failed workplace_path=\(workplace.path, privacy: .public) reason=\(deleteError.localizedDescription, privacy: .public)"
                )
                throw deleteError
            }
        }

        try workplaceStore.deleteWorkplace(workplace.id)
    }

    private func ensureManagedWorkplace(_ workplace: Workplace) throws {
        try LocalPathSafety.validateManagedPath(
            workplace.path,
            within: workplaceRootPath
        )
    }

    private func ensureManagedLocalRepositoryExists(
        for state: RepositorySyncState,
        in workplace: Workplace
    ) throws {
        try ensureManagedWorkplace(workplace)
        try LocalPathSafety.validateManagedPath(
            state.localPath,
            within: workplace.path
        )
        guard state.hasLocalDirectory else {
            throw WorkplaceRuntimeServiceError.missingLocalRepository
        }
    }

    private func isManagedWorkplace(_ workplace: Workplace) -> Bool {
        LocalPathSafety.isWithinDirectory(
            workplace.path,
            rootPath: workplaceRootPath
        )
    }

    private func managedStates(
        in workplace: Workplace,
        repositoryID: UUID? = nil,
        requiresLocalDirectory: Bool
    ) -> [RepositorySyncState] {
        workplaceStore.syncStates.filter { state in
            guard state.workplaceID == workplace.id else { return false }
            guard repositoryID == nil || state.repositoryID == repositoryID else { return false }
            guard LocalPathSafety.isWithinDirectory(state.localPath, rootPath: workplace.path) else {
                return false
            }
            return requiresLocalDirectory == false || state.hasLocalDirectory
        }
    }

    private func switchableStates(in workplace: Workplace) -> [RepositorySyncState] {
        managedStates(in: workplace, requiresLocalDirectory: true)
    }

    nonisolated private static func shouldPushRepository(
        _ state: RepositorySyncState,
        gitService: GitServicing
    ) async throws -> Bool {
        guard let branchStatus = await gitService.branchStatus(in: state.localPath) else {
            throw WorkplaceRuntimeServiceError.unreadableGitStatus
        }

        return branchStatus.hasUnpushedCommits || branchStatus.hasRemoteTrackingBranch == false
    }

    private func normalizeSkippedPushState(_ state: RepositorySyncState) throws {
        guard state.status != .success || state.lastError != nil else { return }

        var updatedState = state
        updatedState.status = .success
        updatedState.lastError = nil
        try workplaceStore.updateSyncState(updatedState)
    }

    private func switchRepositories(
        _ states: [RepositorySyncState],
        resolveBranch: @escaping @Sendable (RepositorySyncState) async -> BatchBranchResolutionResult
    ) async -> WorkplaceBulkBranchSwitchResult {
        let gitService = syncCoordinator.gitService
        let results: [BatchBranchSwitchOperationResult] = await runConcurrentStateOperations(states) { state in
            switch await resolveBranch(state) {
            case .success(let branch):
                do {
                    if await Self.isCurrentBranch(branch, for: state, gitService: gitService) {
                        return .success(Self.succeededState(from: state))
                    }

                    try await GitWorktreeSafety.validateCleanWorkingTree(
                        in: state.localPath,
                        gitService: gitService,
                        blockedOperation: .switchBranch
                    )
                    try await gitService.checkoutBranch(branch, in: state.localPath)
                    return .success(Self.succeededState(from: state))
                } catch {
                    return .failed(
                        Self.failedState(
                            from: state,
                            errorMessage: error.localizedDescription
                        )
                    )
                }
            case .failure(let message):
                return .failed(
                    Self.failedState(
                        from: state,
                        errorMessage: message
                    )
                )
            }
        }

        try? workplaceStore.updateSyncStates(results.map { $0.updatedState })

        let successCount = results.filter { $0.isSuccess }.count
        let failedCount = results.filter { $0.isFailed }.count

        return WorkplaceBulkBranchSwitchResult(
            successCount: successCount,
            failedCount: failedCount
        )
    }

    private func runConcurrentStateOperations<Result: Sendable>(
        _ states: [RepositorySyncState],
        operation: @escaping @Sendable (RepositorySyncState) async -> Result
    ) async -> [Result] {
        guard states.isEmpty == false else { return [] }

        return await withTaskGroup(of: (Int, Result).self, returning: [Result].self) { group in
            let initialTaskCount = min(Self.maxConcurrentBatchTasks, states.count)
            var nextStateIndex = 0
            var results = Array<Result?>(repeating: nil, count: states.count)

            func addTask(for index: Int) {
                let state = states[index]
                group.addTask {
                    (index, await operation(state))
                }
            }

            for _ in 0..<initialTaskCount {
                addTask(for: nextStateIndex)
                nextStateIndex += 1
            }

            while let (index, result) = await group.next() {
                results[index] = result
                guard nextStateIndex < states.count else { continue }
                addTask(for: nextStateIndex)
                nextStateIndex += 1
            }

            return results.compactMap { $0 }
        }
    }

    nonisolated private static func succeededState(
        from state: RepositorySyncState,
        touchLastSyncedAt: Bool = false
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .success
        updatedState.lastError = nil
        if touchLastSyncedAt {
            updatedState.lastSyncedAt = .now
        }
        return updatedState
    }

    nonisolated private static func failedState(
        from state: RepositorySyncState,
        errorMessage: String
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .failed
        updatedState.lastError = errorMessage
        return updatedState
    }

    nonisolated private static func normalizedSkippedPushState(
        from state: RepositorySyncState
    ) -> RepositorySyncState {
        guard state.status != .success || state.lastError != nil else {
            return state
        }

        var updatedState = state
        updatedState.status = .success
        updatedState.lastError = nil
        return updatedState
    }

    nonisolated private static func isCurrentBranch(
        _ branch: String,
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> Bool {
        await gitService.currentBranch(in: state.localPath) == branch
    }

    nonisolated private static func shouldSkipMergeDefaultBranch(
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> Bool {
        guard let defaultBranch = await gitService.defaultBranch(in: state.localPath) else {
            return false
        }
        return await isCurrentBranch(defaultBranch, for: state, gitService: gitService)
    }
}

private extension NSError {
    var underlyingErrors: [NSError] {
        var collected: [NSError] = []

        if let direct = userInfo[NSUnderlyingErrorKey] as? NSError {
            collected.append(direct)
            collected.append(contentsOf: direct.underlyingErrors)
        }

        return collected
    }
}

private extension BatchPushOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .pushed(let state), .skipped(let state), .failed(let state):
            return state
        }
    }

    var isPushed: Bool {
        if case .pushed = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension BatchBranchSwitchOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .success(let state), .failed(let state):
            return state
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension BatchMergeOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .merged(let state), .skipped(let state), .failed(let state):
            return state
        }
    }

    var isMerged: Bool {
        if case .merged = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
