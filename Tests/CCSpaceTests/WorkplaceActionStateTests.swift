import Foundation
import XCTest
@testable import CCSpace

final class WorkplaceActionStateTests: XCTestCase {
    func test_derivesFailedRepositoriesAndActionFlagsForWorkplace() throws {
        let failedRepository = RepositoryConfig(
            id: UUID(),
            gitURL: "https://example.com/failed.git",
            repoName: "failed",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let successRepository = RepositoryConfig(
            id: UUID(),
            gitURL: "https://example.com/success.git",
            repoName: "success",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let otherWorkplaceRepository = RepositoryConfig(
            id: UUID(),
            gitURL: "https://example.com/other.git",
            repoName: "other",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let workplacePath = try makeLocalDirectory(named: "main")
        let failedLocalPath = try makeChildDirectory(named: "failed", in: workplacePath)
        let successLocalPath = try makeChildDirectory(named: "success", in: workplacePath)
        let targetWorkplace = makeWorkplace(
            path: workplacePath,
            selectedRepositoryIDs: [failedRepository.id, successRepository.id]
        )
        let targetWorkplaceID = targetWorkplace.id

        let repositories = [failedRepository, successRepository, otherWorkplaceRepository]
        let syncStates = [
            RepositorySyncState(
                workplaceID: targetWorkplaceID,
                repositoryID: failedRepository.id,
                status: .failed,
                localPath: failedLocalPath,
                lastError: "clone failed",
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: targetWorkplaceID,
                repositoryID: successRepository.id,
                status: .success,
                localPath: successLocalPath,
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: UUID(),
                repositoryID: otherWorkplaceRepository.id,
                status: .failed,
                localPath: "/tmp/other/other",
                lastError: "other workplace",
                lastSyncedAt: nil
            ),
        ]

        let actionState = WorkplaceActionState(
            workplace: targetWorkplace,
            repositories: repositories,
            syncStates: syncStates
        )

        XCTAssertEqual(actionState.workplace, targetWorkplace)
        XCTAssertEqual(actionState.failedRepositories, [failedRepository])
        XCTAssertEqual(actionState.activeRepositoryCount, 0)
        XCTAssertTrue(actionState.hasPullableRepositories)
        XCTAssertFalse(actionState.isBusy)
        XCTAssertTrue(actionState.canRetryFailedRepositories)
        XCTAssertTrue(actionState.canSyncAllRepositories)
        XCTAssertTrue(actionState.canOpenDirectory)
    }

    func test_canRetryFailedRepositoriesIsFalseWhenNoFailedRepositoriesExist() throws {
        let repository = makeRepository(repoName: "success")
        let workplacePath = try makeLocalDirectory(named: "main")
        let localPath = try makeChildDirectory(named: "success", in: workplacePath)
        let workplace = makeWorkplace(
            path: workplacePath,
            selectedRepositoryIDs: [repository.id]
        )

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [repository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .success,
                    localPath: localPath,
                    lastError: nil,
                    lastSyncedAt: nil
                )
            ]
        )

        XCTAssertEqual(actionState.failedRepositories, [])
        XCTAssertFalse(actionState.canRetryFailedRepositories)
        XCTAssertTrue(actionState.canSyncAllRepositories)
    }

    func test_localRepositoryDirectoryMakesWorkplaceSyncAvailableEvenWhenStatusFailed() throws {
        let repository = makeRepository(repoName: "failed-local")
        let workplacePath = try makeLocalDirectory(named: "main")
        let workplace = makeWorkplace(
            path: workplacePath,
            selectedRepositoryIDs: [repository.id]
        )
        let localPath = try makeChildDirectory(named: "failed-local", in: workplacePath)

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [repository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .failed,
                    localPath: localPath,
                    lastError: "old pull error",
                    lastSyncedAt: nil
                )
            ]
        )

        XCTAssertTrue(actionState.hasPullableRepositories)
        XCTAssertTrue(actionState.canSyncAllRepositories)
    }

    func test_canOpenDirectoryIsFalseWhenWorkplacePathIsEmpty() {
        let workplace = makeWorkplace(path: "", selectedRepositoryIDs: [])

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [],
            syncStates: []
        )

        XCTAssertFalse(actionState.canOpenDirectory)
        XCTAssertFalse(actionState.canSyncAllRepositories)
    }

    func test_failedRepositoriesIsEmptyWhenNoSyncStatesMatchWorkplace() {
        let repository = makeRepository(repoName: "failed")
        let workplace = makeWorkplace(
            path: "/tmp/main",
            selectedRepositoryIDs: [repository.id]
        )

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [repository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: UUID(),
                    repositoryID: repository.id,
                    status: .failed,
                    localPath: "/tmp/other/failed",
                    lastError: "other workplace",
                    lastSyncedAt: nil
                )
            ]
        )

        XCTAssertEqual(actionState.failedRepositories, [])
        XCTAssertFalse(actionState.canRetryFailedRepositories)
    }

    func test_failedRepositoriesOnlyIncludesRepositoriesSelectedByWorkplace() {
        let selectedRepository = makeRepository(repoName: "selected")
        let unselectedRepository = makeRepository(repoName: "unselected")
        let workplace = makeWorkplace(
            path: "/tmp/main",
            selectedRepositoryIDs: [selectedRepository.id]
        )

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [selectedRepository, unselectedRepository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: selectedRepository.id,
                    status: .failed,
                    localPath: "/tmp/main/selected",
                    lastError: "selected failed",
                    lastSyncedAt: nil
                ),
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: unselectedRepository.id,
                    status: .failed,
                    localPath: "/tmp/main/unselected",
                    lastError: "unselected failed",
                    lastSyncedAt: nil
                )
            ]
        )

        XCTAssertEqual(actionState.failedRepositories, [selectedRepository])
    }

    func test_busyWorkplaceDisablesRetryAndSyncActions() {
        let repository = makeRepository(repoName: "busy")
        let workplace = makeWorkplace(
            path: "/tmp/main",
            selectedRepositoryIDs: [repository.id]
        )

        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [repository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .pulling,
                    localPath: "/tmp/main/busy",
                    lastError: nil,
                    lastSyncedAt: nil
                )
            ]
        )

        XCTAssertEqual(actionState.activeRepositoryCount, 1)
        XCTAssertTrue(actionState.isBusy)
        XCTAssertFalse(actionState.canRetryFailedRepositories)
        XCTAssertFalse(actionState.canSyncAllRepositories)
    }

    private func makeWorkplace(
        path: String,
        selectedRepositoryIDs: [UUID],
        id: UUID = UUID()
    ) -> Workplace {
        Workplace(
            id: id,
            name: "Main",
            path: path,
            selectedRepositoryIDs: selectedRepositoryIDs,
            createdAt: .distantPast,
            updatedAt: .distantPast
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

    private func makeChildDirectory(named name: String, in parentPath: String) throws -> String {
        let path = URL(fileURLWithPath: parentPath).appendingPathComponent(name).path
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return path
    }

    private func makeRepository(
        repoName: String,
        id: UUID = UUID()
    ) -> RepositoryConfig {
        RepositoryConfig(
            id: id,
            gitURL: "https://example.com/\(repoName).git",
            repoName: repoName,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
