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
            lastSyncedAt: nil
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
            lastSyncedAt: nil
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
            lastSyncedAt: nil
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

    func test_successRepositoryDoesNotExposeStaleErrorMessage() throws {
        let localPath = try makeLocalDirectory(named: "stale-error")
        let state = RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: "git 执行失败",
            lastSyncedAt: nil
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
            lastSyncedAt: nil
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
