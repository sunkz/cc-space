import XCTest
@testable import CCSpace

final class WorkplaceDetailPresentationStateTests: XCTestCase {
    func test_idleWorkplaceEnablesEditSyncAndDelete() throws {
        let repository = makeRepository(repoName: "blog")
        let workplacePath = try makeLocalDirectory(named: "blog")
        let localPath = try makeChildDirectory(named: "blog", in: workplacePath)
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

        let presentationState = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: false
        )

        XCTAssertFalse(presentationState.isActionLocked)
        XCTAssertFalse(presentationState.showsOperationProgress)
        XCTAssertTrue(presentationState.canEditWorkplace)
        XCTAssertTrue(presentationState.canSyncAllRepositories)
        XCTAssertTrue(presentationState.canPushAllRepositories)
        XCTAssertTrue(presentationState.canMergeDefaultBranchIntoCurrent)
        XCTAssertTrue(presentationState.canSwitchRepositoriesToDefaultBranch)
        XCTAssertFalse(presentationState.canSwitchRepositoriesToWorkBranch)
        XCTAssertTrue(presentationState.canOpenDirectory)
        XCTAssertTrue(presentationState.canDeleteWorkplace)
        XCTAssertEqual(presentationState.editHelp, "编辑工作区")
        XCTAssertEqual(presentationState.syncHelp, "同步全部已克隆仓库")
        XCTAssertEqual(presentationState.pushHelp, "推送全部需要推送的仓库")
        XCTAssertEqual(presentationState.switchWorkBranchHelp, "请先配置工作分支名称")
        XCTAssertEqual(presentationState.deleteHelp, "删除工作区")
    }

    func test_performingActionLocksEditSyncAndDeleteImmediately() throws {
        let workplacePath = try makeLocalDirectory(named: "blog")
        let workplace = makeWorkplace(
            path: workplacePath,
            selectedRepositoryIDs: []
        )
        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [],
            syncStates: []
        )

        let presentationState = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: true
        )

        XCTAssertTrue(presentationState.isActionLocked)
        XCTAssertTrue(presentationState.showsOperationProgress)
        XCTAssertFalse(presentationState.canEditWorkplace)
        XCTAssertFalse(presentationState.canSyncAllRepositories)
        XCTAssertFalse(presentationState.canPushAllRepositories)
        XCTAssertFalse(presentationState.canMergeDefaultBranchIntoCurrent)
        XCTAssertFalse(presentationState.canSwitchRepositoriesToDefaultBranch)
        XCTAssertFalse(presentationState.canSwitchRepositoriesToWorkBranch)
        XCTAssertTrue(presentationState.canOpenDirectory)
        XCTAssertFalse(presentationState.canDeleteWorkplace)
        XCTAssertEqual(presentationState.editHelp, "工作区操作进行中")
        XCTAssertEqual(presentationState.syncHelp, "工作区操作进行中")
        XCTAssertEqual(presentationState.pushHelp, "工作区操作进行中")
        XCTAssertEqual(presentationState.switchWorkBranchHelp, "工作区操作进行中")
        XCTAssertEqual(presentationState.deleteHelp, "工作区操作进行中")
    }

    func test_missingDirectoryStillDisablesOpenDirectoryWhenNotBusy() {
        let workplace = makeWorkplace(
            path: "",
            selectedRepositoryIDs: []
        )
        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [],
            syncStates: []
        )

        let presentationState = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: false
        )

        XCTAssertFalse(presentationState.canOpenDirectory)
    }

    func test_deleteConfirmationIncludesPathWhenDirectoryExists() throws {
        let workplacePath = try makeLocalDirectory(named: "blog")
        let workplace = makeWorkplace(
            path: " \(workplacePath) ",
            selectedRepositoryIDs: []
        )

        let confirmationState = WorkplaceDeleteConfirmationState(workplace: workplace)

        XCTAssertEqual(confirmationState.title, "删除 Main")
        XCTAssertEqual(confirmationState.confirmLabel, "确认删除")
        XCTAssertEqual(
            confirmationState.message,
            """
            将删除工作区记录，并删除本地目录中的所有文件。
            目录：\(workplacePath)
            此操作不可撤销。
            """
        )
    }

    func test_deleteConfirmationFallsBackWhenPathIsEmpty() {
        let workplace = makeWorkplace(
            path: "   ",
            selectedRepositoryIDs: []
        )

        let confirmationState = WorkplaceDeleteConfirmationState(workplace: workplace)

        XCTAssertEqual(
            confirmationState.message,
            "将删除工作区记录，此操作不可撤销。"
        )
    }

    func test_repositoryDeleteConfirmationIncludesPathWhenLocalDirectoryExists() throws {
        let localPath = try makeLocalDirectory(named: "blog")
        let confirmationState = WorkplaceRepositoryDeleteConfirmationState(
            repositoryName: "blog",
            localPath: " \(localPath) "
        )

        XCTAssertEqual(confirmationState.title, "删除 blog")
        XCTAssertEqual(confirmationState.confirmLabel, "确认删除")
        XCTAssertEqual(
            confirmationState.message,
            """
            将从当前工作区移除该仓库，并删除本地目录中的所有文件。
            目录：\(localPath)
            此操作不可撤销。
            """
        )
    }

    func test_repositoryDeleteConfirmationFallsBackWhenPathIsEmpty() {
        let confirmationState = WorkplaceRepositoryDeleteConfirmationState(
            repositoryName: "blog",
            localPath: "   "
        )

        XCTAssertEqual(
            confirmationState.message,
            "将从当前工作区移除该仓库，此操作不可撤销。"
        )
    }

    func test_localRepositoriesEnableBatchBranchActions() throws {
        let repository = makeRepository(repoName: "blog")
        let localPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("blog")
            .path
        try FileManager.default.createDirectory(
            atPath: localPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let workplace = Workplace(
            id: UUID(),
            name: "Main",
            path: "/tmp/blog",
            selectedRepositoryIDs: [repository.id],
            branch: "88",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let actionState = WorkplaceActionState(
            workplace: workplace,
            repositories: [repository],
            syncStates: [
                RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repository.id,
                    status: .failed,
                    localPath: localPath,
                    lastError: "old error",
                    lastSyncedAt: nil
                )
            ]
        )

        let presentationState = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: false
        )

        XCTAssertTrue(presentationState.canMergeDefaultBranchIntoCurrent)
        XCTAssertTrue(presentationState.canPushAllRepositories)
        XCTAssertTrue(presentationState.canSwitchRepositoriesToDefaultBranch)
        XCTAssertTrue(presentationState.canSwitchRepositoriesToWorkBranch)
        XCTAssertEqual(presentationState.switchWorkBranchHelp, "切换全部本地仓库到工作分支：88")
    }

    func test_ideaAvailabilityDependsOnInstallationAndDirectory() throws {
        let repository = makeRepository(repoName: "blog")
        let workplacePath = try makeLocalDirectory(named: "blog")
        let localPath = try makeChildDirectory(named: "blog", in: workplacePath)
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

        let withoutIDEA = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: false,
            supportsIDEA: false
        )
        let withIDEA = WorkplaceDetailPresentationState(
            actionState: actionState,
            isPerformingAction: false,
            supportsIDEA: true
        )

        XCTAssertFalse(withoutIDEA.supportsIDEA)
        XCTAssertFalse(withoutIDEA.canOpenInIDEA)
        XCTAssertTrue(withIDEA.supportsIDEA)
        XCTAssertTrue(withIDEA.canOpenInIDEA)
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
}
