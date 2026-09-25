import Foundation

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

        let workplace = try workplaceStore.createWorkplace(
            name: name,
            rootPath: rootPath,
            selectedRepositories: selectedRepositories,
            branch: normalizedBranch
        )

        let directoryExistedBefore = FileManager.default.fileExists(atPath: workplace.path)

        // 与后台定时 pull/push 互斥:锁 key 是精确匹配,必须把目录自身与每条仓库
        // 目标路径一起罩住(与 WorkplaceEditService 的克隆段同构)。
        // 否则落库的 .idle 行使定时 pull 能通过 withLock(localPath) 进入,
        // fetch 会打进克隆到一半的 .git。
        var cloneLockPaths = [workplace.path]
        for repository in selectedRepositories {
            cloneLockPaths.append(
                try WorkplaceStore.repositoryPath(
                    workplacePath: workplace.path,
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
            try? workplaceStore.deleteWorkplace(workplace.id)
            if !directoryExistedBefore {
                try? syncCoordinator.fileSystemService.removeItemIfExists(at: workplace.path)
            }
            throw error
        }
        do {
            let states = try await syncCoordinator.cloneRepositories(
                repositories: selectedRepositories,
                workplace: workplace,
                progressHandler: progressHandler
            )
            try workplaceStore.replaceSyncStates(states, for: workplace.id)
        } catch {
            try? workplaceStore.deleteWorkplace(workplace.id)
            if !directoryExistedBefore {
                try? syncCoordinator.fileSystemService.removeItemIfExists(at: workplace.path)
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
