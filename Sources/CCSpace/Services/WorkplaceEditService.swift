import Foundation
import os

private let editServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceEditService"
)

private struct WorkplaceEditBranchRollback {
    let path: String
    let branch: String
}

/// 克隆任务体"真正开始执行"时登记的目标路径集合。
/// cloneRepositories 的任务体不在 MainActor 上,用 actor 承载以便回调安全写入;
/// 回滚只删除这里的路径——预期清单里"从未开始克隆"的目录可能是用户既有同名目录。
private actor StartedClonePathsBox {
    private var paths: [String] = []

    func append(_ path: String) {
        paths.append(path)
    }

    func snapshot() -> [String] {
        paths
    }
}

/// 编辑工作区过程中的本地目录还原失败。
/// 携带暂存路径,便于在 UI 上告知用户去哪里取回未还原的仓库目录。
enum WorkplaceEditServiceError: LocalizedError {
    case stagedItemRestoreFailed(path: String, reason: String)
    /// 回滚时把仓库切回原分支失败。原始错误多为 git 英文原文/系统描述,
    /// 统一包一层中文再上抛,日志与调用方拿到的都是可读文案。
    case branchRollbackFailed(branch: String, reason: String)
    /// 改名被嵌套工作区挡住:整棵树会被移走,子工作区的路径不会随之重映射。
    case nestedWorkplaceBlocksRename(nestedName: String)

    var errorDescription: String? {
        switch self {
        case let .stagedItemRestoreFailed(path, reason):
            return "还原仓库目录失败（\(reason)）。文件仍保留在暂存目录中，可手动取回：\(path)"
        case let .branchRollbackFailed(branch, reason):
            return "回滚分支切换失败（\(reason)）。仓库可能仍停在编辑过程中的分支：\(branch)"
        case let .nestedWorkplaceBlocksRename(nestedName):
            return "该工作区目录内还有子工作区「\(nestedName)」。改名会整体移动目录，子工作区记录的本地路径不会自动跟随，会导致其状态丢失；请先修改或删除子工作区后再改名"
        }
    }
}

@MainActor
struct WorkplaceEditService {
    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    let syncCoordinator: SyncCoordinator
    let gitService: GitServicing

    func saveWorkplaceEdit(
        workplaceID: UUID,
        name: String,
        selectedRepositoryIDs: [UUID],
        branch: String?,
        links: [CommonLink]? = nil,
        progressHandler: WorkplaceOperationProgressHandler? = nil
    ) async throws {
        // 记录在 await 窗口内被磁盘刷新等路径删除时必须报错,不能静默"保存成功"。
        guard let originalWorkplace = workplaceStore.workplaces.first(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }
        guard selectedRepositoryIDs.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }
        let validatedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBranch = normalizedBranch?.isEmpty == true ? nil : normalizedBranch

        let currentSelectedIDs = Set(originalWorkplace.selectedRepositoryIDs)
        let nextSelectedIDs = Set(selectedRepositoryIDs)
        let removedRepositoryIDs = currentSelectedIDs.subtracting(nextSelectedIDs)
        let addedRepositoryIDs = nextSelectedIDs.subtracting(currentSelectedIDs)
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplaceID }
        // 与其他处一致:循环构建字典,重复 id 时后者覆盖前者而非 trap。
        var repositoryNamesByID = Dictionary<UUID, String>(minimumCapacity: repositoryStore.repositories.count)
        for repository in repositoryStore.repositories {
            repositoryNamesByID[repository.id] = repository.repoName
        }
        let oldPath = originalWorkplace.path
        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let newPath = try WorkplaceStore.workplacePath(
            rootPath: parentPath,
            name: validatedName
        )

        // 大小写归一比较(口径同 WorkplaceStore.renameWorkplace):默认卷大小写不敏感,
        // 仅大小写不同的改名实际指向同一目录,严格字符串比较会误报"与其它工作区重名"。
        let normalizedNewPath = WorkplaceStore.normalizedPath(newPath)
        let lowercasedNewPath = normalizedNewPath.lowercased()
        guard !workplaceStore.workplaces.contains(where: {
            $0.id != workplaceID &&
            WorkplaceStore.normalizedPath($0.path).lowercased() == lowercasedNewPath
        }) else {
            throw WorkplaceStoreError.duplicatePath
        }
        // 存在性探测挪到主线程之外:目标路径可能在网盘/外置盘上,单次 stat 也能
        // 阻塞主线程数秒(口径同 WorkplaceStore.reconcileHasLocalDirectoryFlags)。
        let targetExistsOnDisk: Bool = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: newPath)
        }.value
        guard normalizedNewPath == WorkplaceStore.normalizedPath(oldPath) ||
                targetExistsOnDisk == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }
        try ensureManagedSyncStates(originalStates, within: oldPath)

        // 改名会把整棵 oldPath 移走:若树内还住着**其它工作区**(项目显式支持嵌套工作区,
        // A 内可有 A/B),子工作区记录的 localPath 不会随移动重映射,移动后它们指向已不存在
        // 的旧路径,重启时磁盘刷新会按"目录缺失"把子工作区整条记录删掉(不可恢复)。
        // 在触碰磁盘之前先 fail-closed,让用户先处理子工作区。
        // 改名判定用大小写归一路径:isWithinDirectory 把"同一目录"也判为受管(前缀含相等),
        // 仅大小写不同的改名在默认卷上会把工作区自己当嵌套子工作区而误报拦截。
        // 是否真正执行 move 仍按原始字符串(记录路径字符串的规范化改名也是有效编辑)。
        let renamed = newPath != oldPath
        let pathsDifferIgnoringCase =
            normalizedNewPath.lowercased() != WorkplaceStore.normalizedPath(oldPath).lowercased()
        if renamed, pathsDifferIgnoringCase, let nested = workplaceStore.workplaces.first(where: { candidate in
            candidate.id != workplaceID
                && LocalPathSafety.isWithinDirectory(candidate.path, rootPath: oldPath)
        }) {
            throw WorkplaceEditServiceError.nestedWorkplaceBlocksRename(nestedName: nested.name)
        }

        // ── 磁盘刷新豁免(瞬态标记,必须先于任何磁盘改动)─────────────────────
        // 从此刻起直到 applyWorkplaceEdit 落库,记录仍指向 oldPath,而磁盘上的目录
        // 可能已被整树改名/暂存移出。期间并发的定时磁盘刷新若按这一刻的陈旧磁盘
        // 视图判断,会把"记录在、目录不在"的工作区整条删除(含全部 sync states),
        // 且不可恢复。防线:先把本工作区全部状态行置为瞬态(被移出→.removing,
        // 保留→.switching)。diskRefreshResult 对含瞬态行的工作区一律豁免删除
        // (isWorkplaceOperationInFlight),对瞬态行本身豁免"缺失→假失败"改写。
        // 失败/回滚路径用 originalStates 原样恢复;成功路径由 applyWorkplaceEdit
        // 整体覆盖,瞬态不会外泄。瞬态在重启解码时归位 .idle,崩溃也不遗留。
        workplaceStore.setSyncStatus(.removing, for: workplaceID, repositoryIDs: removedRepositoryIDs)
        workplaceStore.setSyncStatus(.switching, for: workplaceID, repositoryIDs: nextSelectedIDs)

        let removalStagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-space-edit-\(UUID().uuidString)", isDirectory: true)
        var stagedRemovals: [(originalPath: String, stagedPath: String)] = []
        var clonedStates: [RepositorySyncState] = []
        // 预期克隆目标路径清单:用于回滚时把全部潜在目标罩进锁(锁 key 是精确匹配)。
        // 但**删除**必须只按"克隆已启动"清单(startedClonePathsBox)执行:清单里
        // 从未开始克隆的路径在工作区已有同名用户目录时会被误删(旧缺陷)。
        var cloneTargetPaths: [String] = []
        let startedClonePathsBox = StartedClonePathsBox()
        var branchRollbacks: [WorkplaceEditBranchRollback] = []

        do {
            if renamed {
                // 目录移动同样要与仓库级写操作互斥:锁 key 精确匹配,须把
                // 旧/新目录本身与两侧全部仓库路径一起罩住。跨卷移动会退化为
                // "复制整树+删除原树",与并发 git 写入交错会拷出不一致的仓库副本。
                // 与 deleteWorkplace 同一口径:还要罩住**树内其它工作区**的状态行路径
                // (嵌套场景已在前面拦截,这里按磁盘现状兜底,漏锁的代价是仓库被写坏)。
                var renameLockPaths = [oldPath, newPath]
                renameLockPaths.append(contentsOf: originalStates.map(\.localPath))
                renameLockPaths.append(
                    contentsOf: try originalStates.map { state in
                        try updatedSyncStatePath(
                            state,
                            oldWorkplacePath: oldPath,
                            newWorkplacePath: newPath
                        ).localPath
                    }
                )
                renameLockPaths.append(contentsOf: workplaceStore.syncStates.compactMap { candidate in
                    LocalPathSafety.isWithinDirectory(candidate.localPath, rootPath: oldPath)
                        ? candidate.localPath
                        : nil
                })
                // 整棵工作区目录的移动在跨卷时会退化为"复制+删除",可能耗时很久,
                // 移出主线程执行,避免冻结 UI。
                try await RepositoryOperationLock.shared.withLockPaths(renameLockPaths) {
                    try await Self.moveItemOffMainThread(fromPath: oldPath, toPath: newPath)
                }
            }

            var updatedWorkplace = originalWorkplace
            updatedWorkplace.name = validatedName
            updatedWorkplace.path = newPath
            updatedWorkplace.selectedRepositoryIDs = selectedRepositoryIDs
            updatedWorkplace.branch = nextBranch
            // nil=保持原链接:非表单调用方(如其他内部流程)不传 links 时不得清空。
            // 成员赋值不过 Workplace init,净化在此显式收口。
            if let links {
                updatedWorkplace.links = CommonLinksInput.sanitize(links)
            }
            updatedWorkplace.updatedAt = .now

            let updatedStates = try originalStates.map { state in
                try updatedSyncStatePath(
                    state,
                    oldWorkplacePath: oldPath,
                    newWorkplacePath: newPath
                )
            }
            let removedStates = updatedStates.filter { removedRepositoryIDs.contains($0.repositoryID) }
            var retainedStates = updatedStates.filter { nextSelectedIDs.contains($0.repositoryID) }
            let removalProgressTracker =
                removedStates.isEmpty
                ? nil
                : WorkplaceOperationProgressTracker(
                    step: .removingRepositories,
                    totalCount: removedStates.count,
                    progressHandler: progressHandler
                )

            for state in removedStates {
                let repositoryName = repositoryDisplayName(
                    for: state,
                    repositoryNamesByID: repositoryNamesByID
                )
                let stagedPath = try await performProgressTrackedOperation(
                    with: removalProgressTracker,
                    repositoryName: repositoryName
                ) {
                    // 移出暂存(跨卷时为复制+删除)与 pull/push 对同一目录的写互斥。
                    try await RepositoryOperationLock.shared.withLock(path: state.localPath) {
                        try await stageLocalItemForRemovalIfExists(
                            at: state.localPath,
                            stagingRoot: removalStagingRoot.path
                        )
                    }
                }
                if let stagedPath {
                    stagedRemovals.append((originalPath: state.localPath, stagedPath: stagedPath))
                }
            }

            if nextBranch != originalWorkplace.branch, let branchToCheckout = nextBranch, !branchToCheckout.isEmpty {
                let retainedStatesToSwitch = retainedStates.filter { state in
                    !addedRepositoryIDs.contains(state.repositoryID) && state.hasLocalDirectory
                }
                let branchProgressTracker =
                    retainedStatesToSwitch.isEmpty
                    ? nil
                    : WorkplaceOperationProgressTracker(
                        step: .switchingBranches(branch: branchToCheckout),
                        totalCount: retainedStatesToSwitch.count,
                        progressHandler: progressHandler
                    )

                for index in retainedStates.indices where !addedRepositoryIDs.contains(retainedStates[index].repositoryID) {
                    let state = retainedStates[index]
                    guard state.hasLocalDirectory else {
                        continue
                    }
                    let repositoryName = repositoryDisplayName(
                        for: state,
                        repositoryNamesByID: repositoryNamesByID
                    )
                    do {
                        try await performProgressTrackedOperation(
                            with: branchProgressTracker,
                            repositoryName: repositoryName
                        ) {
                            // 与后台定时 pull/push 互斥,避免对同一工作树交错执行写操作。
                            // 闭包内只做 git 操作,切出的原分支带出来再记录,避免捕获 MainActor 状态。
                            let previousBranch: String? = try await RepositoryOperationLock.shared
                                .withLock(path: state.localPath) { () async throws -> String? in
                                    let currentBranch = await gitService.currentBranch(in: state.localPath)
                                    if currentBranch == branchToCheckout {
                                        return nil
                                    }
                                    try await GitWorktreeSafety.validateCleanWorkingTree(
                                        in: state.localPath,
                                        gitService: gitService,
                                        blockedOperation: .switchBranch
                                    )
                                    try await gitService.checkoutBranch(branchToCheckout, in: state.localPath)
                                    guard let currentBranch, currentBranch.isEmpty == false else { return nil }
                                    return currentBranch
                                }
                            if let previousBranch {
                                branchRollbacks.append(
                                    WorkplaceEditBranchRollback(
                                        path: state.localPath,
                                        branch: previousBranch
                                    )
                                )
                            }
                        }
                        retainedStates[index].lastError = nil
                        retainedStates[index].status = .success
                    } catch {
                        retainedStates[index].lastError = UserFacingError.message(for: error)
                        retainedStates[index].status = .failed
                    }
                }
            }

            if addedRepositoryIDs.isEmpty == false {
                let addedRepositories = repositoryStore.repositories.filter { addedRepositoryIDs.contains($0.id) }
                if addedRepositories.isEmpty == false {
                    // 与后台定时 pull/push 互斥,避免克隆过程中对同一目录交错执行写操作。
                    // 锁 key 是精确匹配,只锁工作区根路径罩不住仓库级写操作,
                    // 必须把目录自身与每条待克隆的仓库目标路径一起加锁。
                    // 闭包内只捕获 Sendable 的值(不可变副本),避免捕获 MainActor 隔离状态。
                    let workplaceForClone = updatedWorkplace
                    var expectedClonePaths: [String] = []
                    for repository in addedRepositories {
                        expectedClonePaths.append(
                            try WorkplaceStore.repositoryPath(
                                workplacePath: newPath,
                                repositoryName: repository.repoName
                            )
                        )
                    }
                    // oldPath 也入锁:此刻记录仍指向 oldPath,磁盘刷新的锁快照含
                    // canonical(oldPath) 时,isWorkplaceOperationInFlight 会据此豁免
                    // 该工作区(克隆持续数分钟,期间记录路径在盘上"缺失"是正常的)。
                    var cloneLockPaths = [newPath, oldPath]
                    cloneLockPaths.append(contentsOf: expectedClonePaths)
                    // 在真正进入克隆前登记预期路径(锁等待期间的取消也要罩进锁:
                    // 这些目录要么不存在、要么本就是本次操作要产出的目标)。
                    // 删除范围由 onCloneStarted 单独记录:只有克隆已启动的目录才允许被回滚删掉。
                    cloneTargetPaths = expectedClonePaths
                    clonedStates = try await RepositoryOperationLock.shared.withLockPaths(cloneLockPaths) {
                        try await syncCoordinator.cloneRepositories(
                            repositories: addedRepositories,
                            workplace: workplaceForClone,
                            progressHandler: progressHandler,
                            onCloneStarted: { startedPath in
                                await startedClonePathsBox.append(startedPath)
                            }
                        )
                    }
                    retainedStates.append(contentsOf: clonedStates)
                }
            }

            try workplaceStore.applyWorkplaceEdit(updatedWorkplace, syncStates: retainedStates)
            // 暂存根目录里可能装着多棵被移出的仓库树,递归删除移出主线程。
            await Self.removeItemOffMainThread(
                syncCoordinator.fileSystemService,
                at: removalStagingRoot.path
            )
        } catch {
            // 取消/失败回滚:只删除"克隆已启动"的目录;预期清单继续用于罩锁路径。
            let startedClonePaths = await startedClonePathsBox.snapshot()
            await performEditRollback(
                renamed: renamed,
                oldPath: oldPath,
                newPath: newPath,
                cloneTargetPaths: cloneTargetPaths,
                startedClonePaths: startedClonePaths,
                branchRollbacks: branchRollbacks,
                stagedRemovals: stagedRemovals,
                removalStagingRoot: removalStagingRoot
            )
            // 状态回滚:编辑期间本工作区的行被瞬态标记覆盖(见 do 前的豁免注释),
            // 现用入口快照原样恢复(含被移出仓库的行)。记录若已在 await 窗口内被
            // 并发删除,不能为已消失的工作区补写孤儿行,只留痕。
            if workplaceStore.workplaces.contains(where: { $0.id == workplaceID }) {
                workplaceStore.replaceSyncStates(originalStates, for: workplaceID)
            } else {
                editServiceLog.error(
                    "event=edit_state_rollback_skipped reason=workplace_record_missing workplace_id=\(workplaceID)"
                )
            }
            throw error
        }
    }

    /// 尽力回滚编辑流程已产生的本地变更。所有失败留痕后吞掉(原始错误由调用方抛出);
    /// 暂存目录只有全部还原成功才删除,否则保留供用户手工取回。
    ///
    /// 回滚与正向路径一样必须持锁:等锁的 pull/push 若趁回滚移动目录/切分支时插入,
    /// 会对同一工作树交错写。锁获取本身被取消时降级为无锁尽力回滚(原始错误往往
    /// 就来自取消,回滚不能再等待),并留痕供排查。
    private func performEditRollback(
        renamed: Bool,
        oldPath: String,
        newPath: String,
        cloneTargetPaths: [String],
        startedClonePaths: [String],
        branchRollbacks: [WorkplaceEditBranchRollback],
        stagedRemovals: [(originalPath: String, stagedPath: String)],
        removalStagingRoot: URL
    ) async {
        let lock = RepositoryOperationLock.shared
        var rollbackLockPaths = [oldPath, newPath]
        // 罩锁按"预期克隆路径"全集(含未启动的):与仍在等锁/克隆中的并发任务互斥;
        // 但删除只按 startedClonePaths(克隆已启动),未启动的预期路径可能是用户
        // 既有同名目录,删掉就是毁数据(取消时 cloneRepositories 抛错、clonedStates 为空,
        // 已完成/克隆到一半的目录只有这份已启动清单能覆盖)。
        rollbackLockPaths += cloneTargetPaths
        for item in stagedRemovals {
            rollbackLockPaths += [
                item.originalPath,
                Self.replacePathPrefix(item.originalPath, oldPrefix: newPath, newPrefix: oldPath),
            ]
        }
        for rollback in branchRollbacks {
            rollbackLockPaths += [
                rollback.path,
                Self.replacePathPrefix(rollback.path, oldPrefix: newPath, newPrefix: oldPath),
            ]
        }
        var rollbackLocksAcquired: [String] = []
        // 与 withLockPaths 同一排序(见 RepositoryOperationLock.canonicalLockOrder):
        // 按原始路径排序与按规范 key 排序可能不一致(symlink 别名/大小写差异),
        // 会造成与其它多路径持有者的获取顺序反转,产生环形等待死锁。
        // acquire 内部对 key 的再归一化是幂等的。
        let rollbackLockKeys = RepositoryOperationLock.canonicalLockOrder(rollbackLockPaths)
        for key in rollbackLockKeys {
            do {
                try await lock.acquire(path: key)
                rollbackLocksAcquired.append(key)
            } catch {
                // 等待中被取消:放弃继续收集,带已拿到的锁开始回滚。
                editServiceLog.error("event=rollback_lock_acquire_stopped reason=\(error.localizedDescription)")
                break
            }
        }
        // 本函数所有失败路径都在内部 catch 并留痕,不会中途 throw,
        // 因此按序释放即可,无需 defer(defer 里只能 fire-and-forget,会留出释放真空窗)。
        do {
            // 回滚删除的是整棵已克隆仓库目录,递归删除可能耗时很久,移出主线程。
            // 只删"克隆已启动"的路径:未启动的预期路径不许碰(可能撞用户既有目录)。
            try await removeClonedItemsIfNeeded(startedClonePaths)
        } catch {
            editServiceLog.error("event=rollback_cleanup_failed reason=\(error.localizedDescription)")
        }
        // 暂存根目录里可能装着多棵被移出的仓库树,只有全部还原成功才允许清理;
        // 否则里面残留的仓库树会被一并删掉,变成用户的本地仓库永久丢失。
        var stagedItemsRestored = true
        if renamed {
            var renameRolledBack = true
            do {
                // 回滚同样可能跨卷移动整棵目录树,移出主线程。
                try await Self.moveItemOffMainThread(fromPath: newPath, toPath: oldPath)
            } catch {
                renameRolledBack = false
                editServiceLog.fault("event=rollback_rename_failed reason=\(error.localizedDescription)")
            }
            if renameRolledBack {
                let rollbackBranches = branchRollbacks.map { rollback in
                    WorkplaceEditBranchRollback(
                        path: Self.replacePathPrefix(
                            rollback.path,
                            oldPrefix: newPath,
                            newPrefix: oldPath
                        ),
                        branch: rollback.branch
                    )
                }
                let rollbackStagedRemovals = stagedRemovals.map { item in
                    (
                        originalPath: Self.replacePathPrefix(
                            item.originalPath,
                            oldPrefix: newPath,
                            newPrefix: oldPath
                        ),
                        stagedPath: item.stagedPath
                    )
                }
                do {
                    try await restoreCheckedOutBranches(rollbackBranches)
                } catch {
                    editServiceLog.error("event=rollback_branch_restore_failed reason=\(error.localizedDescription)")
                }
                do {
                    try await restoreStagedItems(rollbackStagedRemovals)
                } catch {
                    editServiceLog.error("event=rollback_restore_failed reason=\(error.localizedDescription)")
                    stagedItemsRestored = false
                }
            } else {
                // 目录树仍在 newPath 下:后续按 oldPath 做的分支恢复/暂存还原注定
                // 级联失败,短路保留现场,暂存目录一律不删(等值于还原失败路径)。
                stagedItemsRestored = false
                editServiceLog.fault("event=rollback_short_circuited reason=directory_still_at_new_path path=\(newPath, privacy: .private)")
            }
        } else {
            do {
                try await restoreCheckedOutBranches(branchRollbacks)
            } catch {
                editServiceLog.error("event=rollback_branch_restore_failed reason=\(error.localizedDescription)")
            }
            do {
                try await restoreStagedItems(stagedRemovals)
            } catch {
                editServiceLog.error("event=rollback_restore_failed reason=\(error.localizedDescription)")
                stagedItemsRestored = false
            }
        }
        if stagedItemsRestored {
            // 递归删除(暂存目录里可能是整棵仓库树)移出主线程。
            await Self.removeItemOffMainThread(
                syncCoordinator.fileSystemService,
                at: removalStagingRoot.path
            )
        } else {
            // 保留暂存目录,用户可从该路径手工取回未还原的仓库目录。
            editServiceLog.error("event=rollback_incomplete staging_root_preserved path=\(removalStagingRoot.path, privacy: .private)")
        }
        for path in rollbackLocksAcquired.reversed() {
            await lock.release(path: path)
        }
    }

    private func updatedSyncStatePath(
        _ state: RepositorySyncState,
        oldWorkplacePath: String,
        newWorkplacePath: String
    ) throws -> RepositorySyncState {
        guard oldWorkplacePath != newWorkplacePath else { return state }
        try LocalPathSafety.validateManagedPath(
            state.localPath,
            within: oldWorkplacePath
        )
        let oldPrefix = WorkplaceStore.normalizedPath(oldWorkplacePath) + "/"
        let normalizedLocalPath = WorkplaceStore.normalizedPath(state.localPath)
        guard normalizedLocalPath.hasPrefix(oldPrefix) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }

        var updatedState = state
        let suffix = String(normalizedLocalPath.dropFirst(oldPrefix.count))
        updatedState.localPath = URL(fileURLWithPath: newWorkplacePath)
            .appendingPathComponent(suffix)
            .path
        return updatedState
    }

    private func ensureManagedSyncStates(
        _ states: [RepositorySyncState],
        within workplacePath: String
    ) throws {
        for state in states {
            try LocalPathSafety.validateManagedPath(
                state.localPath,
                within: workplacePath
            )
        }
    }

    private func stageLocalItemForRemovalIfExists(
        at path: String,
        stagingRoot: String
    ) async throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let stagingDirectory = URL(fileURLWithPath: stagingRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let stagedPath = stagingDirectory
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            .path
        // 移出到 temp 常常是跨卷移动(退化为复制+删除),耗时可达数分钟,移出主线程。
        try await Self.moveItemOffMainThread(fromPath: path, toPath: stagedPath)
        return stagedPath
    }

    private func repositoryDisplayName(
        for state: RepositorySyncState,
        repositoryNamesByID: [UUID: String]
    ) -> String {
        if let repositoryName = repositoryNamesByID[state.repositoryID] {
            return repositoryName
        }
        return URL(fileURLWithPath: state.localPath).lastPathComponent
    }

    private func performProgressTrackedOperation<Result>(
        with tracker: WorkplaceOperationProgressTracker?,
        repositoryName: String,
        operation: () async throws -> Result
    ) async throws -> Result {
        guard let tracker else {
            return try await operation()
        }

        await tracker.didStart(repositoryName: repositoryName)
        do {
            let result = try await operation()
            await tracker.didFinish(repositoryName: repositoryName)
            return result
        } catch {
            await tracker.didFinish(repositoryName: repositoryName)
            throw error
        }
    }

    private func restoreStagedItems(_ stagedItems: [(originalPath: String, stagedPath: String)]) async throws {
        // 还原同样是整棵仓库树的移动,可能跨卷,移出主线程执行。
        // 只捕获 Sendable 的路径列表,失败信息带回主线程记录。
        let failures = await Task.detached(priority: .userInitiated) {
            () -> [(path: String, reason: String)] in
            var failures: [(path: String, reason: String)] = []
            for item in stagedItems.reversed() {
                guard FileManager.default.fileExists(atPath: item.stagedPath) else { continue }
                let parentDirectory = (item.originalPath as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(
                        atPath: parentDirectory,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try FileManager.default.moveItem(atPath: item.stagedPath, toPath: item.originalPath)
                } catch {
                    // 该 reason 会拼进 stagedItemRestoreFailed 的用户可见文案,统一走中文入口。
                    failures.append((path: item.originalPath, reason: UserFacingError.message(for: error)))
                }
            }
            return failures
        }.value

        for failure in failures {
            editServiceLog.error("event=restore_staged_item_failed path=\(failure.path, privacy: .private) reason=\(failure.reason)")
        }
        if let firstFailure = failures.first {
            throw WorkplaceEditServiceError.stagedItemRestoreFailed(
                path: firstFailure.path,
                reason: firstFailure.reason
            )
        }
    }

    /// 按"克隆已启动"路径清单清理本次编辑产生的仓库目录(不存在的路径静默跳过)。
    private func removeClonedItemsIfNeeded(_ paths: [String]) async throws {
        // 递归删除可能耗时数分钟(参考 WorkplaceRuntimeService.removeItemOffMainThread),
        // 移出主线程执行;只捕获 Sendable 的文件系统服务与路径列表,不捕获 self。
        let fileSystem = syncCoordinator.fileSystemService
        try await Task.detached(priority: .userInitiated) {
            for path in paths {
                try fileSystem.removeItemIfExists(at: path)
            }
        }.value
    }

    /// 跨目录移动整棵目录树(跨卷时退化为复制+删除)可能耗时很久,移出主线程执行。
    nonisolated private static func moveItemOffMainThread(fromPath: String, toPath: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(atPath: fromPath, toPath: toPath)
        }.value
    }

    /// 递归删除(暂存目录里可能是整棵仓库树)移出主线程执行;尽力而为,失败不抛错。
    nonisolated private static func removeItemOffMainThread(
        _ fileSystem: any FileSystemServicing,
        at path: String
    ) async {
        // 尽力而为,但失败必须留痕:这里删的可能是整棵仓库树,静默失败会把一份
        // 完整副本留在临时目录里无人知晓(同文件 restoreStagedItems 已是这个口径)。
        await Task.detached(priority: .userInitiated) {
            do {
                try fileSystem.removeItemIfExists(at: path)
            } catch {
                editServiceLog.error(
                    "event=staging_cleanup_failed path=\(path, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }

    private func restoreCheckedOutBranches(
        _ rollbacks: [WorkplaceEditBranchRollback]
    ) async throws {
        guard rollbacks.isEmpty == false else { return }
        let gitService = gitService
        // 回滚必须脱离调用方的取消上下文:正向编辑常因用户取消而失败,回滚若仍在
        // 已取消的任务里跑,checkout 会直接抛 CancellationError,一次都切不回去,
        // 分支停在编辑中途的状态。与 restoreStagedItems 同款:闭包内只捕获 Sendable
        // 值,失败信息(已本地化为中文)带回本方法留痕并上抛。
        let failures = await Task.detached(priority: .userInitiated) {
            () -> [(path: String, branch: String, reason: String)] in
            var failures: [(path: String, branch: String, reason: String)] = []
            for rollback in rollbacks.reversed() {
                do {
                    try await gitService.checkoutBranch(rollback.branch, in: rollback.path)
                } catch {
                    failures.append((
                        path: rollback.path,
                        branch: rollback.branch,
                        reason: UserFacingError.message(for: error)
                    ))
                }
            }
            return failures
        }.value

        for failure in failures {
            editServiceLog.error("event=rollback_single_branch_failed path=\(failure.path) branch=\(failure.branch) reason=\(failure.reason)")
        }
        if let first = failures.first {
            throw WorkplaceEditServiceError.branchRollbackFailed(
                branch: first.branch,
                reason: first.reason
            )
        }
    }

    private static func replacePathPrefix(
        _ path: String,
        oldPrefix: String,
        newPrefix: String
    ) -> String {
        let normalizedPath = WorkplaceStore.normalizedPath(path)
        let normalizedOldPrefix = WorkplaceStore.normalizedPath(oldPrefix)
        // 前缀必须落在**目录边界**上:`/root/ws2/repo` 对 `/root/ws` 同样 hasPrefix,
        // 但那是兄弟目录,按前缀替换会产出错误的重映射。
        let suffix: String
        if normalizedPath == normalizedOldPrefix {
            suffix = ""
        } else if normalizedPath.hasPrefix(normalizedOldPrefix + "/") {
            suffix = String(normalizedPath.dropFirst(normalizedOldPrefix.count))
        } else {
            return path
        }
        return newPrefix + suffix
    }
}
