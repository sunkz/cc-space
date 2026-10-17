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

/// `DiskRefreshService.refresh` 的单飞守卫。标志不能放在 `DiskRefreshService` 自身:它是 `@MainActor struct`、
/// 被 `RootSplitView` 以计算属性构造,每次访问都是**新实例**,实例内标志跨调用不共享;故按 rootPath 键集中共用一份在飞集合。
@MainActor
private final class DiskRefreshSingleFlight {
    static let shared = DiskRefreshSingleFlight()

    private var inFlightRootPaths: Set<String> = []

    func begin(_ rootPath: String) -> Bool {
        inFlightRootPaths.insert(rootPath).inserted
    }

    func end(_ rootPath: String) {
        inFlightRootPaths.remove(rootPath)
    }
}

struct DiskRefreshComputationResult: Sendable {
    let workplaceResult: WorkplaceDiskRefreshResult
    let repositoryResult: RepositoryDeduplicationResult
}

struct DiskRefreshOutcome: Sendable {
    let importedRepositoryCount: Int
}

@MainActor
struct DiskRefreshService {
    typealias RefreshCalculator = @Sendable (DiskRefreshStoreSnapshot, String) async -> DiskRefreshComputationResult

    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    private let refreshCalculator: RefreshCalculator
    private let gitService: GitServicing
    /// 发现阶段并发读取 origin 的上限(每路一个 git 进程)。
    private static let maxConcurrentOriginProbes = 4

    /// 快照不等价时的重试上限。活跃工作区里每次 pull/push 的预标瞬态都会让快照不等价,
    /// 上限过低会让刷新被抖动耗尽而整体放弃(功能事实上不生效)。
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
        // 单飞守卫:同一数据根上的并发刷新只让第一轮生效——`refresh` 内含重试循环与多处 await,重入会重复 apply/import(导入真实写盘)。
        // 生产唯一调用方 RootSplitView.scheduleDiskRefresh 已用 refreshTask 单飞,这里是纵深防御。
        let gate = DiskRefreshSingleFlight.shared
        guard gate.begin(rootPath) else {
            diskRefreshLog.notice("event=refresh_skipped_in_flight")
            return DiskRefreshOutcome(importedRepositoryCount: 0)
        }
        defer { gate.end(rootPath) }

        var retryCount = 0
        while Task.isCancelled == false {
            let snapshot = currentSnapshot()
            let refreshResults = await refreshCalculator(snapshot, rootPath)
            guard Task.isCancelled == false else {
                return DiskRefreshOutcome(importedRepositoryCount: 0)
            }
            retryCount += 1
            guard snapshot == currentSnapshot() else {
                // 快照不等价多半只是 pull/push 的预标瞬态造成的抖动:退避重试,宁可多轮也不放弃刷新。
                guard retryCount <= Self.snapshotRetryBudget else {
                    // 放弃前必须留痕,否则刷新被整体跳过而无人知晓。
                    diskRefreshLog.notice("event=refresh_abandoned reason=snapshot_keeps_changing retries=\(retryCount)")
                    return DiskRefreshOutcome(importedRepositoryCount: 0)
                }
                do {
                    try await Task.sleep(for: .milliseconds(100 * retryCount))
                } catch {
                    // 这里睡不被取消不等于"重试仍不一致":直接退出,不要把取消信号吞掉。
                    return DiskRefreshOutcome(importedRepositoryCount: 0)
                }
                continue
            }

            // 刷新结果与去重硬删除(及其引用清理)单批原子提交,见 RepositoryStore.commitDiskRefresh。
            do {
                try repositoryStore.commitDiskRefresh(
                    workplaceResult: refreshResults.workplaceResult,
                    repositoryResult: refreshResults.repositoryResult,
                    workplaceStore: workplaceStore
                )
            } catch {
                diskRefreshLog.error("event=refresh_apply_failed reason=\(error.localizedDescription, privacy: .public)")
            }
            // 校正之后再做发现:上一步可能刚删掉目录已不存在的工作区记录,发现集合要以刷新后的状态为准。
            let importedCount = await importDiscoveredRepositories()
            return DiskRefreshOutcome(importedRepositoryCount: importedCount)
        }
        return DiskRefreshOutcome(importedRepositoryCount: 0)
    }

    /// 把工作区目录里手动拷入、列表尚未记录的 Git 仓库纳入列表。
    /// 只有"候选枚举 + 逐个读 origin"在后台(每候选一次 git 进程);计划生成与落盘回主 actor,基于此刻 Store 状态重算。
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

        // 每候选一个 `git remote get-url` 进程:串行时整段发现能把单飞闸门占到几十秒,
        // 后续刷新一律被 refresh_skipped_in_flight 挡回。与分支快照同口径限并发;
        // runLimitedTasks 按输入序号回填槽位,发现顺序不变。
        let gitService = gitService
        let probed: [DiscoveredGitRepository?] = await ConcurrencyUtilities.runLimitedTasks(
            candidates,
            maxConcurrentTasks: Self.maxConcurrentOriginProbes
        ) { candidate in
            guard Task.isCancelled == false else { return nil }
            guard let gitURL = await gitService.remoteURL(in: candidate.path) else {
                // 无 origin 的纯本地仓库进不了仓库池(池以 gitURL 为唯一键),留痕跳过。
                diskRefreshLog.notice("event=external_repo_skipped reason=no_origin path=\(candidate.path)")
                return nil
            }
            return DiscoveredGitRepository(
                workplaceID: candidate.workplaceID,
                path: candidate.path,
                folderName: candidate.folderName,
                gitURL: gitURL
            )
        }
        let discovered = probed.compactMap { $0 }

        // 循环内守卫只看"下一个候选开始前";最后一个候选读远端期间才到达的取消必须在这里再拦一道。
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
            // 快照与磁盘扫描之间的窗口无害:之后才 acquire 的锁其操作自身也遵守"先持锁再改盘",中间态对刷新不可见。
            let lockedPathKeys = await RepositoryOperationLock.shared.inFlightPathKeys()
            // 去重保留优先级要参考"谁在被使用":被任一工作区选中/置顶或仍有同步态行的仓库必须优先保留,否则可能硬删正在用的那条。
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
