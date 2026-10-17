import Foundation
import os

private let syncCoordinatorLog = Logger(
    subsystem: "com.ccspace.app",
    category: "SyncCoordinator"
)

struct RepositoryBranchPullOutcomeSummary: Sendable {
    let repositoryName: String
    let outcome: GitPullAllBranchesOutcome
}

struct RepositoryPullResult: Sendable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int
    let failedNames: [String]
    let branchSummaries: [RepositoryBranchPullOutcomeSummary]

    init(
        successCount: Int,
        failedCount: Int,
        skippedCount: Int,
        failedNames: [String] = [],
        branchSummaries: [RepositoryBranchPullOutcomeSummary] = []
    ) {
        self.successCount = successCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.failedNames = failedNames
        self.branchSummaries = branchSummaries
    }

}

private struct PullPreparationResult {
    let pullable: [RepositorySyncState]
    let failed: [RepositorySyncState]
    let skippedCount: Int
}

private enum PullPreparationDecision {
    case pullable(RepositorySyncState)
    case failed(RepositorySyncState)
    case skipped
}

struct SyncCoordinator: Sendable {
    static let maxConcurrentCloneTasks = 2
    static let maxConcurrentPullTasks = 4

    let gitService: GitServicing
    let fileSystemService: FileSystemServicing

    init(
        gitService: GitServicing,
        fileSystemService: FileSystemServicing = FileSystemService()
    ) {
        self.gitService = gitService
        self.fileSystemService = fileSystemService
    }

    /// 调用方必须已持有涉及路径的 RepositoryOperationLock(批量克隆约定);本方法不自行加锁——锁不可重入,内部再加锁会与已持锁的调用方死锁。
    /// `onCloneStarted` 登记**真正开始执行**的克隆目标路径:取消回滚只允许删除"已启动克隆"的目录,按预期清单删会毁掉用户既有同名目录。
    @MainActor
    func cloneRepositories(
        repositories: [RepositoryConfig],
        workplace: Workplace,
        progressHandler: WorkplaceOperationProgressHandler? = nil,
        onCloneStarted: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [RepositorySyncState] {
        // 建目录可能落在网盘/外置盘上,不能在主线程同步做磁盘 IO。
        let fileSystemService = self.fileSystemService
        let workplacePathForCreate = workplace.path
        try await Task.detached(priority: .userInitiated) {
            try fileSystemService.createDirectory(at: workplacePathForCreate)
        }.value

        let gitService = gitService
        let workplaceID = workplace.id
        let workplacePath = workplace.path
        let workplaceBranch = workplace.branch
        let progressTracker = WorkplaceOperationProgressTracker(
            step: .cloningRepositories,
            totalCount: repositories.count,
            progressHandler: progressHandler
        )
        return try await withThrowingTaskGroup(of: RepositorySyncState.self) { group in
            let initialTaskCount = min(Self.maxConcurrentCloneTasks, repositories.count)
            var nextRepositoryIndex = 0

            func addTask(for repository: RepositoryConfig) {
                let repositoryID = repository.id
                let repositoryURL = repository.gitURL
                let repositoryName = repository.repoName

                group.addTask {
                    try Task.checkCancellation()
                    await progressTracker.didStart(repositoryName: repositoryName)
                    // 路径校验失败与 clone 失败同权:落为该仓库的 .failed 状态,不让单个非法路径抛出任务组、作废整批已完成的克隆;只有取消可以冲出任务组。
                    let localPath: String
                    do {
                        localPath = try WorkplaceStore.repositoryPath(
                            workplacePath: workplacePath,
                            repositoryName: repositoryName
                        )
                    } catch is CancellationError {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        throw CancellationError()
                    } catch {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        return RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: "",
                            lastError: UserFacingError.message(for: error),
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                    }
                    let state: RepositorySyncState
                    // 登记"已启动"前查一次存在性:路径已存在说明该目录不是本次克隆创建的(可能是用户既有同名目录),
                    // 照常登记会让编辑回滚按 startedClonePaths 把别人的目录整棵 rm -rf(数据丢失)。
                    let targetPreExists = FileManager.default.fileExists(atPath: localPath)
                    if targetPreExists {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        return RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: localPath,
                            lastError: "目标目录已存在且不是本次克隆创建的,为避免误删既有数据已中止克隆；请调整仓库名或手动处理同名目录后重试",
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                    }
                    // 走到这里说明该仓库的克隆真正开始执行:只有登记过的目录允许被编辑回滚清理。
                    await onCloneStarted?(localPath)
                    do {
                        try await gitService.clone(repositoryURL: repositoryURL, into: localPath)
                    } catch is CancellationError {
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        throw CancellationError()
                    } catch {
                        state = RepositorySyncState(
                            workplaceID: workplaceID,
                            repositoryID: repositoryID,
                            status: .failed,
                            localPath: localPath,
                            lastError: UserFacingError.message(for: error),
                            lastSyncedAt: nil,
                            hasLocalDirectory: false
                        )
                        await progressTracker.didFinish(repositoryName: repositoryName)
                        return state
                    }

                    var checkoutError: String?
                    if let branch = workplaceBranch, !branch.isEmpty {
                        do {
                            try await gitService.checkoutBranch(branch, in: localPath)
                        } catch {
                            checkoutError = UserFacingError.message(for: error)
                        }
                    }

                    state = RepositorySyncState(
                        workplaceID: workplaceID,
                        repositoryID: repositoryID,
                        status: checkoutError != nil ? .failed : .success,
                        localPath: localPath,
                        lastError: checkoutError,
                        lastSyncedAt: .now,
                        hasLocalDirectory: true
                    )
                    await progressTracker.didFinish(repositoryName: repositoryName)
                    return state
                }
            }

            for _ in 0..<initialTaskCount {
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }

            var states: [RepositorySyncState] = []
            var didLogCancellation = false
            while let state = try await group.next() {
                states.append(state)
                guard Task.isCancelled == false else {
                    if didLogCancellation == false {
                        didLogCancellation = true
                        syncCoordinatorLog.notice(
                            "event=clone_batch_cancelled scheduled=\(repositories.count, privacy: .public) remaining=\(repositories.count - nextRepositoryIndex, privacy: .public)"
                        )
                    }
                    group.cancelAll()
                    continue
                }
                guard nextRepositoryIndex < repositories.count else { continue }
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }
            // 取消后 drain 可能"正常"结束,残缺 states 直接 return 会被调用方当成功落库(半创建工作区):终检一次把取消如实上抛。
            try Task.checkCancellation()
            return states
        }
    }

    @MainActor
    func pullRepositories(
        syncStates: [RepositorySyncState],
        workplaceStore: WorkplaceStore
    ) async -> RepositoryPullResult {
        let preparation = await Self.preparePullStates(
            from: syncStates,
            gitService: gitService
        )

        // 预标与本轮拉取都要避开"行上已挂着其它在途操作瞬态"的仓库:无条件写 .pulling 会盖掉别家的 .switching,
        // 而本批结果回写又把它的瞬态归成终态,它自己收口时认不出"我标的那一瞬",行最后停在谁都不负责的状态上。
        // 这些仓库本轮不拉、计入 skippedCount。
        let inFlightKeys = Set(
            workplaceStore.syncStates
                .filter { WorkplaceStore.isTransientSyncStatus($0.status) }
                .map(\.id)
        )
        let pullable = preparation.pullable.filter { inFlightKeys.contains($0.id) == false }
        let failed = preparation.failed.filter { inFlightKeys.contains($0.id) == false }
        let deferredCount = (preparation.pullable.count - pullable.count) + (preparation.failed.count - failed.count)

        let pullingStates = pullable.map { state -> RepositorySyncState in
            var pullingState = state
            pullingState.status = .pulling
            pullingState.lastError = nil
            return pullingState
        }
        // 防抖持久化不抛错（见 WorkplaceStore.persistSyncStates），直接落库。
        // 预标必须**字段级**:pullingStates 取自 preparePullStates 之前的快照,而 prepare 内各仓库并发 branchStatus
        // 探测要挂起一段时间,整行写会把窗口内磁盘刷新写入的 hasLocalDirectory/lastError 退回旧值(lost update)。
        let premarkSource = failed + pullingStates
        let premarkStates = premarkSource.map { incoming -> RepositorySyncState in
            guard let current = workplaceStore.syncStates.first(where: { existing in
                existing.workplaceID == incoming.workplaceID && existing.repositoryID == incoming.repositoryID
            }) else {
                // 行在 await 期间被 prune/去重:没有可叠的底,按原行补录。
                return incoming
            }
            var merged = current
            merged.status = incoming.status
            merged.lastError = incoming.lastError
            return merged
        }
        workplaceStore.updateSyncStates(premarkStates)

        let gitService = gitService
        let repoLock = RepositoryOperationLock.shared
        var successCount = 0
        var failedCount = failed.count
        let pulledResults = await ConcurrencyUtilities.runLimitedTasks(
            pullable,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state -> (original: RepositorySyncState, result: RepositorySyncState, summary: RepositoryBranchPullOutcomeSummary?, cancelled: Bool) in
            let localPath = state.localPath
            let repositoryName = URL(fileURLWithPath: localPath).lastPathComponent
            // 与 push/切分支共用 per-path 锁,避免对同一仓库的跨类操作交错执行。
            do {
                let outcome = try await repoLock.withLock(path: localPath) {
                    try await gitService.pullAllBranches(in: localPath)
                }
                let summary = RepositoryBranchPullOutcomeSummary(repositoryName: repositoryName, outcome: outcome)
                if let primary = outcome.primaryError {
                    var failedState = state
                    failedState.status = .failed
                    failedState.lastError = UserFacingError.message(for: primary)
                    return (state, failedState, summary, false)
                }
                var successState = state
                successState.status = .success
                successState.lastSyncedAt = .now
                successState.lastError = nil
                return (state, successState, summary, false)
            } catch is CancellationError {
                // 取消不是失败:恢复操作前状态(入参 state 未被改动),不落 .failed,避免取消后 UI 出现整列假失败。
                // 标记 cancelled:该行进单独收口通道,不整行覆盖最新行。
                return (state, state, nil, true)
            } catch {
                var failedState = state
                failedState.status = .failed
                failedState.lastError = UserFacingError.message(for: error)
                // 失败原因(网络/锁/权限)只靠这里留痕定位:path 保持默认 private(含用户主目录名),原因显式 public 以便读出。
                syncCoordinatorLog.error(
                    "event=pull_failed path=\(state.localPath) reason=\(failedState.lastError ?? "", privacy: .public)"
                )
                return (state, failedState, nil, false)
            }
        }
        let branchSummaries = pulledResults.compactMap(\.summary)

        var cancelledSnapshots: [RepositorySyncState] = []
        var results: [(original: RepositorySyncState, result: RepositorySyncState)] = []
        results.reserveCapacity(pulledResults.count)
        for entry in pulledResults {
            // 取消行不参与计数、不进结果:整行旧快照落库会把等锁期间磁盘刷新/其它操作写入的最新字段覆盖回 pull 前(lost update)。
            if entry.cancelled {
                cancelledSnapshots.append(entry.original)
                continue
            }
            if entry.result.status == .success {
                successCount += 1
            } else if entry.result.status == .failed {
                failedCount += 1
            }
            results.append((entry.original, entry.result))
        }
        // 回写按字段级增量合并(premarkedTransient: .pulling,见 RepositorySyncState.merging):pull 持锁可达数分钟,
        // 期间磁盘刷新/其他操作改写的无关字段会被整行覆盖(lost update);.pulling 瞬态归位为结果终态。
        var updates: [RepositorySyncState] = []
        updates.reserveCapacity(results.count)
        for entry in results {
            guard let current = workplaceStore.syncStates.first(where: {
                $0.workplaceID == entry.original.workplaceID && $0.repositoryID == entry.original.repositoryID
            }) else {
                // 行在 pull 窗口内被去重/prune:原样回写结果行补录(仅仍被选中的行会真正落库)。
                updates.append(entry.result)
                continue
            }
            if let merged = RepositorySyncState.merging(
                updated: entry.result,
                onto: entry.original,
                in: current,
                premarkedTransient: .pulling
            ) {
                updates.append(merged)
            }
        }
        // 取消收口:只归位本批 pull 预标的 .pulling 瞬态(按字段增量合并到最新行,
        // 其余字段保留最新值);行上若是其它在途操作的瞬态则不动,由其自行收口。
        var cancelledRestores: [RepositorySyncState] = []
        for snapshot in cancelledSnapshots {
            guard let current = workplaceStore.syncStates.first(where: {
                $0.workplaceID == snapshot.workplaceID && $0.repositoryID == snapshot.repositoryID
            }) else { continue }
            guard current.status == .pulling else { continue }
            var restored = current
            restored.status = snapshot.status
            restored.lastError = snapshot.lastError
            cancelledRestores.append(restored)
        }
        workplaceStore.updateSyncStates(updates + cancelledRestores)

        // 失败名单须覆盖两段:准备阶段探测失败(branchStatus 不可读/目录异常,未进 pull 任务)与 pull 任务内失败,
        // 否则通知里只报后者、前者凭空消失。
        let failedNames = failed.map { URL(fileURLWithPath: $0.localPath).lastPathComponent }
            + results
                .filter { $0.result.status == .failed }
                .map { URL(fileURLWithPath: $0.result.localPath).lastPathComponent }

        return RepositoryPullResult(
            successCount: successCount,
            failedCount: failedCount,
            skippedCount: preparation.skippedCount + deferredCount,
            failedNames: failedNames,
            branchSummaries: branchSummaries
        )
    }

    private static func preparePullStates(
        from syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> PullPreparationResult {
        let candidates = syncStates.filter { state in
            state.localPath.isEmpty == false &&
            state.hasLocalDirectory &&
            state.status != .cloning &&
            state.status != .pulling &&
            state.status != .switching &&
            state.status != .removing
        }

        let decisions = await ConcurrencyUtilities.runLimitedTasks(
            candidates,
            maxConcurrentTasks: Self.maxConcurrentPullTasks
        ) { state in
            // branchStatus 探测在锁外执行,与后续加锁的 pull 之间存在 TOCTOU 窗口(上游配置恰好变化时探测结果过期)。
            // 可接受的取舍:探测只读且瞬时,全程持锁会让每个仓库的检查串行排队,锁竞争代价远高于偶发的过期判断。
            guard let branchStatus = await gitService.branchStatus(in: state.localPath) else {
                return PullPreparationDecision.failed(
                    failedPullInspectionState(
                        state,
                        message: "无法读取仓库 Git 状态"
                    )
                )
            }
            guard branchStatus.hasRemoteTrackingBranch else {
                return PullPreparationDecision.skipped
            }
            // 不把 .failed 预翻成 .success 作"准备态":取消时本闭包返回入参原始状态,预翻会落库成"显示成功但残留旧 lastError"。
            return PullPreparationDecision.pullable(state)
        }

        var pullableStates: [RepositorySyncState] = []
        var failedStates: [RepositorySyncState] = []
        var skippedCount = 0

        for decision in decisions {
            switch decision {
            case .pullable(let pullable):
                pullableStates.append(pullable)
            case .failed(let failed):
                failedStates.append(failed)
            case .skipped:
                skippedCount += 1
            }
        }

        return PullPreparationResult(
            pullable: pullableStates,
            failed: failedStates,
            skippedCount: skippedCount
        )
    }

    // MARK: - 独立窗口的仓库写操作(与后台 pull/push/切分支共用 per-path 锁)
    //
    // Diff / 提交记录窗口不经主工作区流程直接发起写操作;不走锁时定时 pull 可在"git add 已执行、commit 未跑"的中间态插进来。

    @MainActor
    func discardFileChanges(filePath: String, in directory: String) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.discardChanges(filePath: filePath, in: directory)
        }
    }

    @MainActor
    func commitAllChanges(message: String, in directory: String) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.commitAllChanges(message: message, in: directory)
        }
    }

    @MainActor
    func createBranchFromRevision(
        _ branch: String,
        fromRev rev: String,
        in directory: String
    ) async throws {
        try await RepositoryOperationLock.shared.withLock(path: directory) {
            try await gitService.createBranch(branch, fromRev: rev, in: directory)
        }
    }
}

private func failedPullInspectionState(
    _ state: RepositorySyncState,
    message: String
) -> RepositorySyncState {
    var failedState = state
    failedState.status = .failed
    failedState.lastError = message
    return failedState
}
