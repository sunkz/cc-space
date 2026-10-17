import Foundation

/// 单个工作区的派生操作状态;与 `workplace.selectedRepositoryIDs` 取交集,避免过宽输入把无关仓库算进来。
struct WorkplaceActionState {
    let workplace: Workplace
    let hasLocalRepositories: Bool
    let isBusy: Bool
    let canOpenDirectory: Bool

    init(
        workplace: Workplace,
        syncStates: [RepositorySyncState],
        probedWorkplaceDirectoryExists: Bool = false
    ) {
        self.workplace = workplace

        let selectedRepositoryIDs = Set(workplace.selectedRepositoryIDs)
        var hasLocal = false
        var hasAnySyncStateRow = false
        var activeCount = 0

        for state in syncStates where state.workplaceID == workplace.id && selectedRepositoryIDs.contains(state.repositoryID) {
            hasAnySyncStateRow = true
            if state.hasLocalDirectory { hasLocal = true }
            switch state.status {
            case .cloning, .pulling, .switching, .removing: activeCount += 1
            case .failed, .idle, .success: break
            }
        }

        hasLocalRepositories = hasLocal
        isBusy = activeCount > 0
        // 有同步态行时用"任一仓库目录在盘"推断工作区目录存在(仓库目录必在工作区目录下),省掉 body 里的主线程 fileExists;
        // 没有仓库行时无从推断,只能用视图侧后台探测的缓存结果。本 init 在 body 求值链上,绝不能做同步磁盘 IO(网盘/外置盘可卡主线程数秒)。
        if hasAnySyncStateRow {
            canOpenDirectory = hasLocal
        } else {
            canOpenDirectory = probedWorkplaceDirectoryExists
        }
    }
}
