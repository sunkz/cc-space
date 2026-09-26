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

@MainActor
struct DiskRefreshService {
    typealias RefreshCalculator = @Sendable (DiskRefreshStoreSnapshot, String) async -> DiskRefreshComputationResult

    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    private let refreshCalculator: RefreshCalculator

    init(
        workplaceStore: WorkplaceStore,
        repositoryStore: RepositoryStore,
        refreshCalculator: @escaping RefreshCalculator = DiskRefreshService.defaultRefreshCalculator
    ) {
        self.workplaceStore = workplaceStore
        self.repositoryStore = repositoryStore
        self.refreshCalculator = refreshCalculator
    }

    func refresh(rootPath: String) async {
        var retryCount = 0
        while Task.isCancelled == false {
            let snapshot = currentSnapshot()
            let refreshResults = await refreshCalculator(snapshot, rootPath)
            guard Task.isCancelled == false else { return }
            retryCount += 1
            guard snapshot == currentSnapshot() else {
                guard retryCount <= 3 else {
                    // 放弃前必须留痕:此前静默 return,刷新被整体跳过而无人知晓。
                    diskRefreshLog.notice("event=refresh_abandoned reason=snapshot_keeps_changing retries=\(retryCount)")
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    // 取消不是"重试仍不一致",直接退出,不要把取消信号吞掉。
                    return
                }
                continue
            }

            workplaceStore.applyDiskRefreshResult(refreshResults.workplaceResult)
            repositoryStore.applyDeduplicationResult(refreshResults.repositoryResult)
            // 去重硬删除仓库后立即清理工作区对它的引用(选中/置顶/同步态),
            // 而不是等下次启动 pruneReferencesToRepositories——期间 UI 会展示悬空引用。
            if refreshResults.repositoryResult.changed {
                do {
                    try workplaceStore.pruneReferencesToRepositories(
                        validRepositoryIDs: Set(repositoryStore.repositories.map(\.id))
                    )
                } catch {
                    // 清理失败不影响本次刷新结果,留痕后由下次启动对账兜底。
                    diskRefreshLog.error("event=post_dedup_prune_failed reason=\(error.localizedDescription)")
                }
            }
            return
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
