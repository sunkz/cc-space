import Foundation
import os

private let diskRefreshLog = Logger(
    subsystem: "com.ccspace.app",
    category: "DiskRefreshService"
)

struct DiskRefreshStoreSnapshot: Equatable, Sendable {
    let workplace: WorkplaceStoreSnapshot
    let repositories: [RepositoryConfig]
}

struct DiskRefreshComputationResult: Sendable {
    let workplaceResult: WorkplaceDiskRefreshResult
    let repositoryResult: RepositoryDeduplicationResult
}

struct DiskRefreshOutcome: Sendable, Equatable {
    /// 本轮从磁盘发现并纳入工作区列表的 Git 仓库数(手动拷入的目录)。
    let importedRepositoryCount: Int
}

@MainActor
struct DiskRefreshService {
    typealias RefreshCalculator = @Sendable (DiskRefreshStoreSnapshot, String) async -> DiskRefreshComputationResult

    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    private let refreshCalculator: RefreshCalculator
    /// 读候选目录的 origin 地址用(GitServicing 是 Sendable,可在后台等待)。
    private let gitService: GitServicing

    /// 快照不等价时的重试上限。活跃工作区里每次 pull/push 的预标瞬态都会让快照
    /// 不等价，上限过低会让刷新被抖动耗尽而整体放弃（功能事实上不生效）。
    static let snapshotRetryBudget = 8

    init(
        workplaceStore: WorkplaceStore,
        repositoryStore: RepositoryStore,
        gitService: GitServicing = GitService(),
        refreshCalculator: @escaping RefreshCalculator = DiskRefreshService.defaultRefreshCalculator
    ) {
        self.workplaceStore = workplaceStore
        self.repositoryStore = repositoryStore
        self.gitService = gitService
        self.refreshCalculator = refreshCalculator
    }

    @discardableResult
    func refresh(rootPath: String) async -> DiskRefreshOutcome {
        var retryCount = 0
        while Task.isCancelled == false {
            let snapshot = currentSnapshot()
            let refreshResults = await refreshCalculator(snapshot, rootPath)
            guard Task.isCancelled == false else {
                return DiskRefreshOutcome(importedRepositoryCount: 0)
            }
            retryCount += 1
            guard snapshot == currentSnapshot() else {
                // 预算要足够宽松:活跃工作区里每次 pull/push 的预标瞬态都会让快照
                // 不等价,预算 3 次时刷新几乎必然被"抖动"耗尽而整体放弃(功能事实上
                // 不生效)。改为退避 + 更高上限,宁可多轮也不放弃刷新。
                guard retryCount <= Self.snapshotRetryBudget else {
                    // 放弃前必须留痕:此前静默 return,刷新被整体跳过而无人知晓。
                    diskRefreshLog.notice("event=refresh_abandoned reason=snapshot_keeps_changing retries=\(retryCount)")
                    return DiskRefreshOutcome(importedRepositoryCount: 0)
                }
                do {
                    try await Task.sleep(for: .milliseconds(100 * retryCount))
                } catch {
                    // 取消不是"重试仍不一致",直接退出,不要把取消信号吞掉。
                    return DiskRefreshOutcome(importedRepositoryCount: 0)
                }
                continue
            }

            // 刷新结果与去重硬删除(及其引用清理)单批原子提交,见
            // RepositoryStore.commitDiskRefresh 的说明。
            do {
                try repositoryStore.commitDiskRefresh(
                    workplaceResult: refreshResults.workplaceResult,
                    repositoryResult: refreshResults.repositoryResult,
                    workplaceStore: workplaceStore
                )
            } catch {
                diskRefreshLog.error("event=refresh_apply_failed reason=\(error.localizedDescription, privacy: .public)")
            }
            // 校正之后再做发现:上一步可能刚删掉目录已不存在的工作区记录,
            // 发现阶段的工作区集合要以刷新后的状态为准。
            let importedCount = await importDiscoveredRepositories()
            return DiskRefreshOutcome(importedRepositoryCount: importedCount)
        }
        return DiskRefreshOutcome(importedRepositoryCount: 0)
    }

    /// 把工作区目录里手动拷入、列表尚未记录的 Git 仓库纳入列表。
    ///
    /// 只有"候选枚举 + 逐个读 origin"这段在后台(每个候选一次 git 进程),
    /// 计划生成与落盘回到主 actor,基于此刻的 Store 状态重算(见
    /// RepositoryStore.commitImportedRepositories)。
    private func importDiscoveredRepositories() async -> Int {
        let snapshot = currentSnapshot()
        let lockedPathKeys = await RepositoryOperationLock.shared.inFlightPathKeys()
        let candidates = await Task.detached(priority: .utility) {
            ExternalRepositoryImport.candidates(
                workplaces: snapshot.workplace.workplaces,
                syncStates: snapshot.workplace.syncStates,
                lockedPathKeys: lockedPathKeys
            )
        }.value
        guard candidates.isEmpty == false else { return 0 }

        var discovered: [DiscoveredGitRepository] = []
        discovered.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard Task.isCancelled == false else { return 0 }
            guard let gitURL = await gitService.remoteURL(in: candidate.path) else {
                // 无 origin 的纯本地仓库进不了仓库池(它以 gitURL 为唯一键),留痕跳过。
                diskRefreshLog.notice("event=external_repo_skipped reason=no_origin path=\(candidate.path)")
                continue
            }
            discovered.append(DiscoveredGitRepository(
                workplaceID: candidate.workplaceID,
                path: candidate.path,
                folderName: candidate.folderName,
                gitURL: gitURL
            ))
        }

        // 循环内守卫只看"下一个候选开始前";最后一个候选读远端期间才到达的
        // 取消必须在这里也拦一道,否则取消语义下仍会提交导入(10-10 review 修复)。
        guard Task.isCancelled == false else { return 0 }

        do {
            return try repositoryStore.commitImportedRepositories(
                discovered: discovered,
                workplaceStore: workplaceStore
            )
        } catch {
            diskRefreshLog.error("event=external_repo_import_failed reason=\(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func currentSnapshot() -> DiskRefreshStoreSnapshot {
        DiskRefreshStoreSnapshot(
            workplace: WorkplaceStore.snapshot(
                workplaces: workplaceStore.workplaces,
                syncStates: workplaceStore.syncStates
            ),
            repositories: repositoryStore.repositories
        )
    }

    nonisolated private static func defaultRefreshCalculator(
        snapshot: DiskRefreshStoreSnapshot,
        rootPath: String
    ) async -> DiskRefreshComputationResult {
        await Task.detached(priority: .utility) {
            // 取锁的 in-flight 快照:创建/改名/克隆进行中的路径要在豁免名单里跳过破坏性改写。
            // 快照与磁盘扫描之间的窗口无害:拿快照之后才 acquire 的锁,其操作自身
            // 也遵守"先持锁再改盘"的顺序,磁盘与记录的中间态对刷新不可见。
            let lockedPathKeys = await RepositoryOperationLock.shared.inFlightPathKeys()
            // 去重保留优先级要参考"谁在被使用":被任一工作区选中/置顶或仍有
            // 同步态行的仓库必须优先保留,否则可能硬删掉正在用的那条而留下新重复项。
            var protectedRepositoryIDs: Set<UUID> = []
            for workplace in snapshot.workplace.workplaces {
                protectedRepositoryIDs.formUnion(workplace.selectedRepositoryIDs)
                protectedRepositoryIDs.formUnion(workplace.pinnedRepositoryIDs)
            }
            protectedRepositoryIDs.formUnion(snapshot.workplace.syncStates.map(\.repositoryID))
            return DiskRefreshComputationResult(
                workplaceResult: WorkplaceStore.diskRefreshResult(
                    workplaces: snapshot.workplace.workplaces,
                    syncStates: snapshot.workplace.syncStates,
                    rootPath: rootPath,
                    lockedPathKeys: lockedPathKeys
                ),
                repositoryResult: RepositoryStore.deduplicationResult(
                    for: snapshot.repositories,
                    protectedRepositoryIDs: protectedRepositoryIDs
                )
            )
        }.value
    }
}
