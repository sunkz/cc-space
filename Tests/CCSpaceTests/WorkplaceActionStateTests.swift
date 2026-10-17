import Foundation
import XCTest
@testable import CCSpace

final class WorkplaceActionStateTests: XCTestCase {


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
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .failed,
                    localPath: localPath,
                    lastError: "old pull error",
                    lastSyncedAt: nil,
                    hasLocalDirectory: true
                )
            ]
        )

        XCTAssertTrue(actionState.hasLocalRepositories)
    }

    func test_canOpenDirectoryIsFalseWhenWorkplacePathIsEmpty() {
        let workplace = makeWorkplace(path: "", selectedRepositoryIDs: [])

        let actionState = WorkplaceActionState(
            workplace: workplace,
            syncStates: []
        )

        XCTAssertFalse(actionState.canOpenDirectory)
    }

    func test_canOpenDirectoryUsesInjectedProbeWhenNoSyncStateRows() {
        // init 在 body 求值链上,空工作区不得同步 stat 磁盘:
        // 目录存在性完全由视图侧后台探测结果注入,此处不触盘。
        let workplace = makeWorkplace(
            path: "/tmp/ccspace-nonexistent-\(UUID().uuidString)",
            selectedRepositoryIDs: []
        )

        let unprobed = WorkplaceActionState(
            workplace: workplace,
            syncStates: []
        )
        let probedPresent = WorkplaceActionState(
            workplace: workplace,
            syncStates: [],
            probedWorkplaceDirectoryExists: true
        )
        let probedAbsent = WorkplaceActionState(
            workplace: workplace,
            syncStates: [],
            probedWorkplaceDirectoryExists: false
        )

        XCTAssertFalse(unprobed.canOpenDirectory)
        XCTAssertTrue(probedPresent.canOpenDirectory)
        XCTAssertFalse(probedAbsent.canOpenDirectory)
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
