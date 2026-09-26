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

        // 必须先持锁、再落库。旧顺序(先 createWorkplace 落库、后逐条 acquire)存在
        // 致命窗口:记录已持久化而目录尚未创建,期间 acquire 可能因后台 pull 持锁而
        // 挂起数分钟,定时磁盘刷新会把"记录存在、目录不存在"的新工作区整条删除,
        // 克隆完成后只剩孤儿 sync states,且目录已存在导致 UI 无法再建同名工作区。
        // 锁路径与 createWorkplace 用同一组静态推导(workplacePath/repositoryPath),
        // 二者必然一致;推导抛错(名称非法等)与 createWorkplace 抛的是同一批错误。
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // 与 createWorkplace 的校验顺序一致:空根目录要报"请先设置工作区根目录",
        // 不能让下面的路径推导先抛出"异常本地路径"。
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
        // 用 acquire/手动 release 而非 withLockPaths:后者的 operation 是 @Sendable
        // 闭包(非 MainActor),罩不住这里要调的 MainActor Store 方法。
        // 逐个 acquire 并记录已持有路径:某条 acquire 抛出(如等待锁时被取消)时,
        // 前面已持有的路径必须逆序释放——锁是进程级单例,漏放会把对应仓库的
        // pull/push/切分支挂死到 App 重启;lock 自身的 acquire 只管单条路径,
        // 不知道本轮循环里还持有哪些,回滚只能由调用方做。
        let lock = RepositoryOperationLock.shared
        let lockPaths = Set(cloneLockPaths).sorted()
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
            // createWorkplace 校验过"目录不存在",目录只可能由本次克隆创建,
            // 失败时可直接删除而不踩到用户既有目录。
            let states = try await syncCoordinator.cloneRepositories(
                repositories: selectedRepositories,
                workplace: workplace,
                progressHandler: progressHandler
            )
            workplaceStore.replaceSyncStates(states, for: workplace.id)
        } catch {
            // 清理仍是尽力而为,但失败必须留痕:静默吞掉会留下孤儿记录/目录,
            // 且"目录已存在"会让 UI 无法再建同名工作区,无从排查。
            do {
                try workplaceStore.deleteWorkplace(workplace.id)
            } catch {
                createServiceLog.error(
                    "event=create_cleanup_delete_workplace_failed workplace_id=\(workplace.id) reason=\(error.localizedDescription)"
                )
            }
            do {
                try syncCoordinator.fileSystemService.removeItemIfExists(at: workplace.path)
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
}
