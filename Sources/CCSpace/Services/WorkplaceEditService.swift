import Foundation
import os

private let editServiceLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceEditService"
)

private struct WorkplaceEditBranchRollback {
    let path: String
    let branch: String
}

@MainActor
struct WorkplaceEditService {
    let workplaceStore: WorkplaceStore
    let repositoryStore: RepositoryStore
    let syncCoordinator: SyncCoordinator
    let gitService: GitServicing

    func saveWorkplaceEdit(
        workplaceID: UUID,
        name: String,
        selectedRepositoryIDs: [UUID],
        branch: String?
    ) async throws {
        guard let originalWorkplace = workplaceStore.workplaces.first(where: { $0.id == workplaceID }) else { return }
        guard selectedRepositoryIDs.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }
        let validatedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBranch = normalizedBranch?.isEmpty == true ? nil : normalizedBranch

        let currentSelectedIDs = Set(originalWorkplace.selectedRepositoryIDs)
        let nextSelectedIDs = Set(selectedRepositoryIDs)
        let removedRepositoryIDs = currentSelectedIDs.subtracting(nextSelectedIDs)
        let addedRepositoryIDs = nextSelectedIDs.subtracting(currentSelectedIDs)
        let originalStates = workplaceStore.syncStates.filter { $0.workplaceID == workplaceID }
        let oldPath = originalWorkplace.path
        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let newPath = try WorkplaceStore.workplacePath(
            rootPath: parentPath,
            name: validatedName
        )

        let normalizedNewPath = URL(fileURLWithPath: newPath).standardizedFileURL.path
        guard !workplaceStore.workplaces.contains(where: {
            $0.id != workplaceID &&
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedNewPath
        }) else {
            throw WorkplaceStoreError.duplicatePath
        }
        guard normalizedNewPath == WorkplaceStore.normalizedPath(oldPath) ||
                FileManager.default.fileExists(atPath: newPath) == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }
        try ensureManagedSyncStates(originalStates, within: oldPath)

        let renamed = newPath != oldPath
        let removalStagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-space-edit-\(UUID().uuidString)", isDirectory: true)
        var stagedRemovals: [(originalPath: String, stagedPath: String)] = []
        var clonedStates: [RepositorySyncState] = []
        var branchRollbacks: [WorkplaceEditBranchRollback] = []

        do {
            if renamed {
                try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            }

            var updatedWorkplace = originalWorkplace
            updatedWorkplace.name = validatedName
            updatedWorkplace.path = newPath
            updatedWorkplace.selectedRepositoryIDs = selectedRepositoryIDs
            updatedWorkplace.branch = nextBranch
            updatedWorkplace.updatedAt = .now

            let updatedStates = try originalStates.map { state in
                try updatedSyncStatePath(
                    state,
                    oldWorkplacePath: oldPath,
                    newWorkplacePath: newPath
                )
            }
            let removedStates = updatedStates.filter { removedRepositoryIDs.contains($0.repositoryID) }
            var retainedStates = updatedStates.filter { nextSelectedIDs.contains($0.repositoryID) }

            for state in removedStates {
                if let stagedPath = try stageLocalItemForRemovalIfExists(
                    at: state.localPath,
                    stagingRoot: removalStagingRoot.path
                ) {
                    stagedRemovals.append((originalPath: state.localPath, stagedPath: stagedPath))
                }
            }

            if nextBranch != originalWorkplace.branch, let branchToCheckout = nextBranch, !branchToCheckout.isEmpty {
                for index in retainedStates.indices where !addedRepositoryIDs.contains(retainedStates[index].repositoryID) {
                    guard retainedStates[index].hasLocalDirectory else {
                        continue
                    }
                    do {
                        let currentBranch = await gitService.currentBranch(in: retainedStates[index].localPath)
                        if currentBranch == branchToCheckout {
                            retainedStates[index].lastError = nil
                            retainedStates[index].status = .success
                            continue
                        }
                        try await GitWorktreeSafety.validateCleanWorkingTree(
                            in: retainedStates[index].localPath,
                            gitService: gitService,
                            blockedOperation: .switchBranch
                        )
                        try await gitService.checkoutBranch(branchToCheckout, in: retainedStates[index].localPath)
                        if let currentBranch,
                           currentBranch.isEmpty == false {
                            branchRollbacks.append(
                                WorkplaceEditBranchRollback(
                                    path: retainedStates[index].localPath,
                                    branch: currentBranch
                                )
                            )
                        }
                        retainedStates[index].lastError = nil
                        retainedStates[index].status = .success
                    } catch {
                        retainedStates[index].lastError = error.localizedDescription
                        retainedStates[index].status = .failed
                    }
                }
            }

            if addedRepositoryIDs.isEmpty == false {
                let addedRepositories = repositoryStore.repositories.filter { addedRepositoryIDs.contains($0.id) }
                if addedRepositories.isEmpty == false {
                    clonedStates = try await syncCoordinator.cloneRepositories(
                        repositories: addedRepositories,
                        workplace: updatedWorkplace
                    )
                    retainedStates.append(contentsOf: clonedStates)
                }
            }

            try workplaceStore.applyWorkplaceEdit(updatedWorkplace, syncStates: retainedStates)
            try? syncCoordinator.fileSystemService.removeItemIfExists(at: removalStagingRoot.path)
        } catch {
            do {
                try removeClonedItemsIfNeeded(clonedStates)
            } catch {
                editServiceLog.error("event=rollback_cleanup_failed reason=\(error.localizedDescription)")
            }
            do {
                try await restoreCheckedOutBranches(branchRollbacks)
            } catch {
                editServiceLog.error("event=rollback_branch_restore_failed reason=\(error.localizedDescription)")
            }
            do {
                try restoreStagedItems(stagedRemovals)
            } catch {
                editServiceLog.error("event=rollback_restore_failed reason=\(error.localizedDescription)")
            }
            try? syncCoordinator.fileSystemService.removeItemIfExists(at: removalStagingRoot.path)
            if renamed {
                do {
                    try FileManager.default.moveItem(atPath: newPath, toPath: oldPath)
                } catch {
                    editServiceLog.error("event=rollback_rename_failed reason=\(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    private func updatedSyncStatePath(
        _ state: RepositorySyncState,
        oldWorkplacePath: String,
        newWorkplacePath: String
    ) throws -> RepositorySyncState {
        guard oldWorkplacePath != newWorkplacePath else { return state }
        try LocalPathSafety.validateManagedPath(
            state.localPath,
            within: oldWorkplacePath
        )
        let oldPrefix = WorkplaceStore.normalizedPath(oldWorkplacePath) + "/"
        let normalizedLocalPath = WorkplaceStore.normalizedPath(state.localPath)
        guard normalizedLocalPath.hasPrefix(oldPrefix) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }

        var updatedState = state
        let suffix = String(normalizedLocalPath.dropFirst(oldPrefix.count))
        updatedState.localPath = URL(fileURLWithPath: newWorkplacePath)
            .appendingPathComponent(suffix)
            .path
        return updatedState
    }

    private func ensureManagedSyncStates(
        _ states: [RepositorySyncState],
        within workplacePath: String
    ) throws {
        for state in states {
            try LocalPathSafety.validateManagedPath(
                state.localPath,
                within: workplacePath
            )
        }
    }

    private func stageLocalItemForRemovalIfExists(
        at path: String,
        stagingRoot: String
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let stagingDirectory = URL(fileURLWithPath: stagingRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let stagedPath = stagingDirectory
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            .path
        try FileManager.default.moveItem(atPath: path, toPath: stagedPath)
        return stagedPath
    }

    private func restoreStagedItems(_ stagedItems: [(originalPath: String, stagedPath: String)]) throws {
        for item in stagedItems.reversed() {
            guard FileManager.default.fileExists(atPath: item.stagedPath) else { continue }
            let parentDirectory = (item.originalPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try FileManager.default.moveItem(atPath: item.stagedPath, toPath: item.originalPath)
        }
    }

    private func removeClonedItemsIfNeeded(_ states: [RepositorySyncState]) throws {
        for state in states {
            try syncCoordinator.fileSystemService.removeItemIfExists(at: state.localPath)
        }
    }

    private func restoreCheckedOutBranches(
        _ rollbacks: [WorkplaceEditBranchRollback]
    ) async throws {
        for rollback in rollbacks.reversed() {
            try await gitService.checkoutBranch(
                rollback.branch,
                in: rollback.path
            )
        }
    }
}
