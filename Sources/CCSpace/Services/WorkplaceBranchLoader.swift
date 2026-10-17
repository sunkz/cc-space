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
    static let maxConcurrentSnapshotLoads = 8

    static func loadBranchSnapshots(
        for syncStates: [RepositorySyncState],
        gitService: GitServicing
    ) async -> [RepositoryBranchCacheKey: RepositoryBranchSnapshot] {
        let branchStates = syncStates.filter(\.hasLocalDirectory)
        guard branchStates.isEmpty == false else { return [:] }

        let results = await ConcurrencyUtilities.runLimitedTasks(
            branchStates,
            maxConcurrentTasks: maxConcurrentSnapshotLoads
        ) { state in
            await loadBranchSnapshot(for: state, gitService: gitService)
        }

        var snapshots: [RepositoryBranchCacheKey: RepositoryBranchSnapshot] = [:]
        for (key, snapshot) in results {
            if let snapshot {
                snapshots[key] = snapshot
            }
        }
        return snapshots
    }

    private static func loadBranchSnapshot(
        for state: RepositorySyncState,
        gitService: GitServicing
    ) async -> (RepositoryBranchCacheKey, RepositoryBranchSnapshot?) {
        let key = RepositoryBranchCacheKey(state: state)

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        // 只取主快照:远端跟踪分支没有读取点,多取一次等于每仓库每轮刷新白跑一个 git 进程。
        let info = await gitService.branchSnapshotInfo(in: state.localPath)
        guard let info else {
            return (key, nil)
        }

        guard Task.isCancelled == false else {
            return (key, nil)
        }

        return (
            key,
            RepositoryBranchSnapshot(
                currentBranch: info.currentBranch,
                branches: normalizedBranches(
                    info.branches,
                    currentBranch: info.currentBranch
                ),
                status: info.status
            )
        )
    }
}


/// 分支名单归一:去空白、去重、按本地化标准顺序排序。
/// localizedStandardCompare 上千分支代价可观——必须在加载时(后台线程)做一次,弹窗展示状态只消费结果、不重排序。
enum BranchListNormalization {
    static func normalized(_ branches: [String]) -> [String] {
        Array(
            Set(
                branches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private func normalizedBranches(
    _ branches: [String],
    currentBranch: String?
) -> [String] {
    // 先把当前分支补进名单再归一,保证元数据未到时它也始终在列表里。
    var inputs = branches
    if let currentBranch {
        inputs.append(currentBranch)
    }
    return BranchListNormalization.normalized(inputs)
}
