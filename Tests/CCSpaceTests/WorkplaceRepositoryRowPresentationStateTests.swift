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
            actionsDisabled: false,
            supportsIDEA: true
        )

        XCTAssertTrue(presentationState.canRetryClone)
        XCTAssertFalse(presentationState.canPullLatest)
        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertTrue(presentationState.supportsIDEA)
        XCTAssertTrue(presentationState.canOpenInIDEA)
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
            actionsDisabled: false,
            supportsIDEA: true
        )

        XCTAssertFalse(presentationState.canRetryClone)
        XCTAssertTrue(presentationState.canPullLatest)
        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertTrue(presentationState.canOpenInIDEA)
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
            actionsDisabled: true,
            supportsIDEA: true
        )

        XCTAssertFalse(presentationState.canRetryClone)
        XCTAssertFalse(presentationState.canPullLatest)
        XCTAssertFalse(presentationState.canPushToRemote)
        XCTAssertTrue(presentationState.canOpenLocalActions)
        XCTAssertTrue(presentationState.canOpenInIDEA)
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
            actionsDisabled: false,
            supportsIDEA: true
        )

        XCTAssertFalse(presentationState.canOpenLocalActions)
        XCTAssertFalse(presentationState.canOpenInIDEA)
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
            actionsDisabled: false,
            supportsIDEA: false
        )

        XCTAssertTrue(presentationState.canPushToRemote)
        XCTAssertFalse(presentationState.canOpenInIDEA)
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
            actionsDisabled: false,
            supportsIDEA: true
        )

        XCTAssertFalse(presentationState.canDeleteRepository)
        XCTAssertTrue(presentationState.canOpenInIDEA)
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
