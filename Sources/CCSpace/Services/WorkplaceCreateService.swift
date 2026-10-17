import Foundation
import os

private let createServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceCreateService"
)

@MainActor
struct WorkplaceCreateService {
    let repositoryStore: RepositoryStore
    let workplaceStore: WorkplaceStore
    let syncCoordinator: SyncCoordinator

    func createWorkplace(
        name: String,
        rootPath: String,
        selectedRepositoryIDs: [UUID],
        branch: String?,
        progressHandler: WorkplaceOperationProgressHandler? = nil
    ) async throws -> Workplace {
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = trimmedBranch?.isEmpty == true ? nil : trimmedBranch
        let selectedRepositories = repositoryStore.repositories.filter {
            selectedRepositoryIDs.contains($0.id)
        }

        // 必须先持锁、再落库:反过来时"记录已持久化而目录尚未创建"的窗口里 acquire 可能因后台 pull 挂起数分钟,
        // 定时磁盘刷新会把该工作区整条删除只剩孤儿 sync states,且残留目录让 UI 无法再建同名工作区。
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // 与 createWorkplace 的校验顺序一致:空根目录要报"请先设置工作区根目录",不能让下面的路径推导先抛"异常本地路径"。
        guard trimmedRootPath.isEmpty == false else { throw WorkplaceStoreError.missingRootPath }
        guard selectedRepositories.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }
        let candidatePath = try WorkplaceStore.workplacePath(rootPath: trimmedRootPath, name: name)
        var cloneLockPaths = [candidatePath]
        for repository in selectedRepositories {
            cloneLockPaths.append(
                try WorkplaceStore.repositoryPath(
                    workplacePath: candidatePath,
                    repositoryName: repository.repoName
                )
            )
        }
        // 用 acquire/手动 release 而非 withLockPaths:后者的 operation 是 @Sendable 闭包(非 MainActor),罩不住这里要调的 MainActor Store 方法。
        // acquire 只管单条路径、不知道本轮已持有哪些:某条抛出(如等锁时被取消)时调用方必须逆序释放——
        // 锁是进程级单例,漏放会把该仓库的 pull/push/切分支挂死到 App 重启。
        let lock = RepositoryOperationLock.shared
        // 必须与 withLockPaths 同一排序(见 RepositoryOperationLock.canonicalLockOrder):按原始路径排序会与其它
        // 多路径持有者的获取顺序反转,构成环形等待死锁。
        let lockPaths = RepositoryOperationLock.canonicalLockOrder(cloneLockPaths)
        var acquiredPaths: [String] = []
        do {
            for path in lockPaths {
                try await lock.acquire(path: path)
                acquiredPaths.append(path)
            }
        } catch {
            for path in acquiredPaths.reversed() {
                await lock.release(path: path)
            }
            throw error
        }

        let workplace: Workplace
        do {
            workplace = try workplaceStore.createWorkplace(
                name: name,
                rootPath: rootPath,
                selectedRepositories: selectedRepositories,
                branch: normalizedBranch
            )
        } catch {
            for path in acquiredPaths.reversed() {
                await lock.release(path: path)
            }
            throw error
        }

        do {
            // createWorkplace 校验过"目录不存在",目录只可能由本次克隆创建,失败时可直接删除而不踩到用户既有目录。
            let states = try await syncCoordinator.cloneRepositories(
                repositories: selectedRepositories,
                workplace: workplace,
                progressHandler: progressHandler
            )
            workplaceStore.replaceSyncStates(states, for: workplace.id)
        } catch {
            // 清理仍是尽力而为,但失败必须留痕:静默吞掉会留下孤儿记录/目录,让 UI 无法再建同名工作区且无从排查。
            do {
                try workplaceStore.deleteWorkplace(workplace.id)
            } catch {
                createServiceLog.error(
                    "event=create_cleanup_delete_workplace_failed workplace_id=\(workplace.id) reason=\(error.localizedDescription)"
                )
            }
            do {
                // 半克隆树可达数 GB,递归删除必须移出主线程;仍要"删完再放锁":删除 await 完成后才走到下面的 release。
                try await Self.removeItemOffMainThread(
                    syncCoordinator.fileSystemService,
                    at: workplace.path
                )
            } catch {
                createServiceLog.error(
                    "event=create_cleanup_remove_directory_failed path=\(workplace.path, privacy: .private) reason=\(error.localizedDescription)"
                )
            }
            for path in acquiredPaths.reversed() {
                await lock.release(path: path)
            }
            throw error
        }
        for path in acquiredPaths.reversed() {
            await lock.release(path: path)
        }
        return workplace
    }

    /// 递归删除半克隆的工作区目录树(可达数 GB)必须移出主线程;删除期间仍持锁,由调用方 await 完成后再释放。
    nonisolated private static func removeItemOffMainThread(
        _ fileSystem: any FileSystemServicing,
        at path: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try fileSystem.removeItemIfExists(at: path)
        }.value
    }
}
