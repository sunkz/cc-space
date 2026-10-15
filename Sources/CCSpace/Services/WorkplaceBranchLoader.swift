import Foundation

/// 工作区分支快照的加载与归一(Service 层)。
///
/// 从 `Views/WorkplaceDetailSupport.swift` 迁入:本类型直接驱动 `GitServicing`
/// 做并发取数,属于业务编排,按 AGENTS.md 的依赖方向
/// (`Views → AppState/Stores → Services → Models`)不能留在 Views 层——
/// 此前详情页/分支弹窗的 git 取数编排挂在 Views 里,View 侧实际在直接调 git。
/// 行为逐字保持不变,只是换了所在层。

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

        // 只取主快照。此前这里并行多取一次远端跟踪分支填到
        // RepositoryBranchSnapshot.remoteBranches,而该字段全仓没有任何读取点——
        // 等于每次刷新(每仓库)白跑一个 git 进程。
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
/// 排序用的是 localizedStandardCompare,上千分支代价可观——必须在加载时
/// (后台线程)做一次,弹窗展示状态只消费结果,不做重排序。
enum BranchListNormalization {
    static func remoteBranches(_ branches: [String]) -> [String] {
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
    // 与远端名单共用 `BranchListNormalization`(去空+去重+本地化排序);
    // 这里先把当前分支补进去,保证元数据未到时它也始终在列表里。
    var inputs = branches
    if let currentBranch {
        inputs.append(currentBranch)
    }
    return BranchListNormalization.remoteBranches(inputs)
}
