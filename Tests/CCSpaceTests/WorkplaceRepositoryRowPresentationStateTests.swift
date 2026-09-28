import XCTest
@testable import CCSpace

final class WorkplaceRepositoryRowPresentationStateTests: XCTestCase {
    func test_failedRepositoryCanRetryWhenNotLocked() throws {
        let localPath = try makeLocalDirectory(named: "failed-retry")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .failed,
            localPath: localPath,
            lastError: "clone failed",
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false
        )

        XCTAssertTrue(presentationState.canRetryClone)
        XCTAssertTrue(presentationState.canRefreshStatus)
        XCTAssertFalse(presentationState.canPullLatest)
        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertTrue(presentationState.canDeleteRepository)
        XCTAssertTrue(presentationState.canCreateMergeRequest)
        XCTAssertTrue(presentationState.canSwitchBranch)
        XCTAssertEqual(presentationState.visibleErrorMessage, "clone failed")
    }

    func test_successRepositoryCanPullWhenNotLocked() throws {
        let localPath = try makeLocalDirectory(named: "success-pull")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: nil,
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false
        )

        XCTAssertFalse(presentationState.canRetryClone)
        XCTAssertTrue(presentationState.canRefreshStatus)
        XCTAssertTrue(presentationState.canPullLatest)
        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertTrue(presentationState.canDeleteRepository)
        XCTAssertTrue(presentationState.canCreateMergeRequest)
        XCTAssertTrue(presentationState.canSwitchBranch)
        XCTAssertNil(presentationState.visibleErrorMessage)
    }

    func test_lockedActionsDisableRetryAndPull() throws {
        let localPath = try makeLocalDirectory(named: "locked-actions")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .failed,
            localPath: localPath,
            lastError: "clone failed",
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: true
        )

        XCTAssertFalse(presentationState.canRetryClone)
        XCTAssertFalse(presentationState.canRefreshStatus)
        XCTAssertFalse(presentationState.canPullLatest)
        XCTAssertFalse(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertFalse(presentationState.canDeleteRepository)
        XCTAssertFalse(presentationState.canCreateMergeRequest)
        XCTAssertFalse(presentationState.canSwitchBranch)
        XCTAssertEqual(presentationState.visibleErrorMessage, "clone failed")
    }

    func test_missingLocalPathDisablesFinderAndTerminalActions() {
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: "",
            lastError: nil,
            lastSyncedAt: nil
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false
        )

        XCTAssertFalse(presentationState.canRefreshStatus)
        XCTAssertFalse(presentationState.canOpenLocalActions)
        XCTAssertFalse(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canDeleteRepository)
        XCTAssertFalse(presentationState.canCreateMergeRequest)
        XCTAssertFalse(presentationState.canSwitchBranch)
        XCTAssertNil(presentationState.visibleErrorMessage)
    }

    /// 网页动作不依赖本地目录:未克隆/目录缺失时,菜单里必须保留
    /// 「在浏览器打开仓库」这条唯一直达远端主页的入口。
    func test_webActionSurvivesMissingLocalDirectory() {
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .idle,
            localPath: "",
            lastError: nil,
            lastSyncedAt: nil
        )

        let withRepositoryConfig = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false,
            hasRepositoryConfig: true
        )

        XCTAssertFalse(withRepositoryConfig.canOpenLocalActions)
        XCTAssertTrue(withRepositoryConfig.canOpenRepositoryWeb)
        // 动作锁不影响打开网页:浏览器与 git 进程互不干扰。
        let lockedWithConfig = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: true,
            hasRepositoryConfig: true
        )
        XCTAssertTrue(lockedWithConfig.canOpenRepositoryWeb)

        let withoutRepositoryConfig = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false
        )

        XCTAssertFalse(withoutRepositoryConfig.canOpenRepositoryWeb)
    }

    /// 菜单尾段分组顺序是纯值(视图按 menuGroups 渲染):已克隆仓库的网页动作
    /// 由本地动作组内插槽(分支比较后)渲染,头部不再重复出 .webActions 组;
    /// 未克隆仓库本地组缺席,必须有头部 .webActions 兜底——菜单里恒出现一次。
    /// 分隔线恒排动作组之后、删除之前。
    func test_menuGroupsRenderWebActionOnceWithLocalSlotAndUnclonedFallback() {
        func makeState(
            status: SyncStatus,
            hasLocalDirectory: Bool,
            hasRepositoryConfig: Bool
        ) -> WorkplaceRepositoryRowPresentationState {
            WorkplaceRepositoryRowPresentationState(
                syncState: RepositorySyncState(
                    workplaceID: UUID(),
                    repositoryID: UUID(),
                    status: status,
                    localPath: hasLocalDirectory ? "/tmp/example-repo" : "",
                    lastError: nil,
                    lastSyncedAt: nil,
                    hasLocalDirectory: hasLocalDirectory
                ),
                hasRetryRepository: true,
                hasPullRepository: true,
                allowsDeleteRepository: true,
                actionsDisabled: false,
                hasRepositoryConfig: hasRepositoryConfig
            )
        }

        // 已克隆 + 有远端配置:网页动作走本地组内插槽,头部组不重复渲染。
        XCTAssertEqual(
            makeState(status: .success, hasLocalDirectory: true, hasRepositoryConfig: true).menuGroups,
            [.localActions, .primaryDivider, .delete]
        )
        // 未克隆:本地组缺席,网页动作仍渲染(上一轮修的入口缺失回归点),分隔线保留。
        XCTAssertEqual(
            makeState(status: .idle, hasLocalDirectory: false, hasRepositoryConfig: true).menuGroups,
            [.webActions, .primaryDivider, .delete]
        )
        // 既无本地动作也无网页动作:只剩删除,不留悬空分隔线。
        XCTAssertEqual(
            makeState(status: .idle, hasLocalDirectory: false, hasRepositoryConfig: false).menuGroups,
            [.delete]
        )
        // 有本地目录但未配远端地址:本地组 + 分隔线 + 删除(四种可达组合的第四种)。
        XCTAssertEqual(
            makeState(status: .idle, hasLocalDirectory: true, hasRepositoryConfig: false).menuGroups,
            [.localActions, .primaryDivider, .delete]
        )
    }

    func test_successRepositoryDoesNotExposeStaleErrorMessage() throws {
        let localPath = try makeLocalDirectory(named: "stale-error")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: "git 执行失败",
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: false
        )

        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canDeleteRepository)
        XCTAssertNil(presentationState.visibleErrorMessage)
    }

    func test_lastRepositoryDisablesDeleteAction() throws {
        let localPath = try makeLocalDirectory(named: "single-repo")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: nil,
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        let presentationState = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: false,
            actionsDisabled: false
        )

        XCTAssertFalse(presentationState.canDeleteRepository)
    }

    func test_stashAndViewChangesRequireUncommittedChanges() throws {
        let localPath = try makeLocalDirectory(named: "stash-availability")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: nil,
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        func makeState(hasUncommittedChanges: Bool?) -> WorkplaceRepositoryRowPresentationState {
            WorkplaceRepositoryRowPresentationState(
                syncState: state,
                hasRetryRepository: true,
                hasPullRepository: true,
                allowsDeleteRepository: true,
                actionsDisabled: false,
                hasUncommittedChanges: hasUncommittedChanges
            )
        }

        // 有未提交改动时可 Stash、可查看改动。
        XCTAssertTrue(makeState(hasUncommittedChanges: true).canStashChanges)
        XCTAssertTrue(makeState(hasUncommittedChanges: true).canViewChanges)
        // 干净工作区与状态未知(快照未加载)时禁用。
        XCTAssertFalse(makeState(hasUncommittedChanges: false).canStashChanges)
        XCTAssertFalse(makeState(hasUncommittedChanges: false).canViewChanges)
        XCTAssertFalse(makeState(hasUncommittedChanges: nil).canStashChanges)
        XCTAssertFalse(makeState(hasUncommittedChanges: nil).canViewChanges)

        // 有改动但操作锁定时仍禁用。
        let locked = WorkplaceRepositoryRowPresentationState(
            syncState: state,
            hasRetryRepository: true,
            hasPullRepository: true,
            allowsDeleteRepository: true,
            actionsDisabled: true,
            hasUncommittedChanges: true
        )
        XCTAssertFalse(locked.canStashChanges)
        XCTAssertFalse(locked.canViewChanges)
    }

    func test_conflictsDisableStashAndViewChangesAndEnableAbort() throws {        let localPath = try makeLocalDirectory(named: "conflict-actions")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: nil,
            lastSyncedAt: nil,
            hasLocalDirectory: true
        )

        func makeState(hasConflicts: Bool?, actionsDisabled: Bool = false) -> WorkplaceRepositoryRowPresentationState {
            WorkplaceRepositoryRowPresentationState(
                syncState: state,
                hasRetryRepository: true,
                hasPullRepository: true,
                allowsDeleteRepository: true,
                actionsDisabled: actionsDisabled,
                hasUncommittedChanges: true,
                hasConflicts: hasConflicts
            )
        }

        // git 在有未合并路径时拒绝 stash → Stash 禁用;"查看改动"必须保持可用:
        // 冲突时用户最需要的就是看 diff;中止入口打开。
        let conflicted = makeState(hasConflicts: true)
        XCTAssertFalse(conflicted.canStashChanges)
        XCTAssertTrue(conflicted.canViewChanges, "冲突态下查看改动是解决冲突的前提,不得被 Stash 规则连带禁用")
        XCTAssertTrue(conflicted.canAbortInterruptedOperation)

        let clean = makeState(hasConflicts: false)
        XCTAssertTrue(clean.canStashChanges)
        XCTAssertTrue(clean.canViewChanges)
        XCTAssertFalse(clean.canAbortInterruptedOperation)

        // 快照未加载(nil)与操作锁定均不提供中止入口。
        XCTAssertFalse(makeState(hasConflicts: nil).canAbortInterruptedOperation)
        XCTAssertFalse(makeState(hasConflicts: true, actionsDisabled: true).canAbortInterruptedOperation)
    }

    func test_abortConfirmationStateNamesOperationAndFallsBackGenerically() {
        let merge = WorkplaceRepositoryAbortConfirmationState(operation: .merge)
        XCTAssertEqual(merge.title, "中止合并")
        XCTAssertEqual(merge.confirmLabel, "确认中止")
        XCTAssertTrue(merge.message.contains("丢弃进行中的合并"))

        let rebase = WorkplaceRepositoryAbortConfirmationState(operation: .rebase)
        XCTAssertEqual(rebase.title, "中止变基")

        let unknown = WorkplaceRepositoryAbortConfirmationState(operation: nil)
        XCTAssertEqual(unknown.title, "中止当前操作")
        XCTAssertTrue(unknown.message.contains("丢弃进行中的当前操作"))
    }

    func test_branchPillShowsCurrentBranchNameAndGenericTooltip() {
        let pillState = WorkplaceRepositoryBranchPillState(
            currentBranch: " feature/login ",
            defaultBranch: "main",
            hasAvailableBranches: true
        )

        XCTAssertEqual(pillState?.title, "feature/login")
        XCTAssertEqual(pillState?.quickHelp, "当前分支")
        XCTAssertEqual(pillState?.isDefault, false)
    }

    func test_branchPillMarksDefaultBranchAndEmptyBranchMenu() {
        let pillState = WorkplaceRepositoryBranchPillState(
            currentBranch: "main",
            defaultBranch: " main ",
            hasAvailableBranches: false
        )

        XCTAssertEqual(
            pillState?.quickHelp,
            "当前分支，暂无可切换的本地分支"
        )
        XCTAssertEqual(pillState?.title, "main")
        XCTAssertEqual(pillState?.isDefault, true)
    }

    func test_blankCurrentBranchDoesNotShowBranchPill() {
        XCTAssertNil(
            WorkplaceRepositoryBranchPillState(
                currentBranch: "   ",
                defaultBranch: "main",
                hasAvailableBranches: true
            )
        )
    }

    private func makeLocalDirectory(named name: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
            .path
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return path
    }
}
