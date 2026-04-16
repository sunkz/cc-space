import Foundation
import os

private let workplaceStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceStore"
)

struct WorkplaceDiskRefreshResult: Sendable {
    let workplaces: [Workplace]
    let syncStates: [RepositorySyncState]
    let changed: Bool
}

struct WorkplaceStoreSnapshot: Equatable, Sendable {
    let workplaces: [Workplace]
    let syncStates: [RepositorySyncState]
}

enum WorkplaceStoreError: LocalizedError, Equatable {
    case missingRootPath
    case emptyName
    case invalidName
    case noRepositoriesSelected
    case duplicatePath
    case pathAlreadyExistsOnDisk

    var errorDescription: String? {
        switch self {
        case .missingRootPath:
            return "请先设置工作区根目录"
        case .emptyName:
            return "工作区名称不能为空"
        case .invalidName:
            return "工作区名称不能包含路径分隔符，且不能为 . 或 .."
        case .noRepositoriesSelected:
            return "至少选择一个仓库"
        case .duplicatePath:
            return "目标工作区已存在"
        case .pathAlreadyExistsOnDisk:
            return "目标工作区目录已存在，请更换名称"
        }
    }
}

@MainActor
final class WorkplaceStore: ObservableObject {
    @Published private(set) var workplaces: [Workplace]
    @Published private(set) var syncStates: [RepositorySyncState]
    private let fileStore: JSONFileStore

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        self.workplaces =
            (try? fileStore.loadIfPresent([Workplace].self, from: "workplaces.json", default: [])) ?? []
        self.syncStates =
            (try? fileStore.loadIfPresent([RepositorySyncState].self, from: "sync-states.json", default: []))
            ?? []
    }

    nonisolated static func normalizedPath(_ path: String) -> String {
        LocalPathSafety.normalizedPath(path)
    }

    nonisolated static func workplacePath(
        rootPath: String,
        name: String
    ) throws -> String {
        let validatedName = try validatedWorkplaceName(name)
        return try LocalPathSafety.childPath(
            in: rootPath,
            component: validatedName,
            fieldName: "工作区名称"
        )
    }

    nonisolated static func repositoryPath(
        workplacePath: String,
        repositoryName: String
    ) throws -> String {
        try LocalPathSafety.childPath(
            in: workplacePath,
            component: repositoryName,
            fieldName: "仓库名称"
        )
    }

    nonisolated private static func validatedWorkplaceName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { throw WorkplaceStoreError.emptyName }
        do {
            return try LocalPathSafety.validateComponent(
                trimmedName,
                fieldName: "工作区名称"
            )
        } catch LocalPathSafetyError.invalidComponent {
            throw WorkplaceStoreError.invalidName
        }
    }

    private func persistWorkplaces(_ newWorkplaces: [Workplace]) throws {
        try fileStore.save(newWorkplaces, as: "workplaces.json")
        workplaces = newWorkplaces
    }

    private func persistSyncStates(_ newSyncStates: [RepositorySyncState]) throws {
        try fileStore.save(newSyncStates, as: "sync-states.json")
        syncStates = newSyncStates
    }

    private func persist(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) throws {
        let previousWorkplaces = workplaces
        try fileStore.save(newWorkplaces, as: "workplaces.json")
        do {
            try fileStore.save(newSyncStates, as: "sync-states.json")
        } catch {
            try? fileStore.save(previousWorkplaces, as: "workplaces.json")
            throw error
        }

        workplaces = newWorkplaces
        syncStates = newSyncStates
    }

    func createWorkplace(name: String, rootPath: String, selectedRepositories: [RepositoryConfig], branch: String? = nil) throws
        -> Workplace
    {
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedRootPath.isEmpty == false else { throw WorkplaceStoreError.missingRootPath }
        guard selectedRepositories.isEmpty == false else { throw WorkplaceStoreError.noRepositoriesSelected }

        let trimmedName = try Self.validatedWorkplaceName(name)
        let path = try Self.workplacePath(
            rootPath: trimmedRootPath,
            name: trimmedName
        )
        let normalizedNewPath = Self.normalizedPath(path)
        guard workplaces.contains(where: { Self.normalizedPath($0.path) == normalizedNewPath }) == false else {
            throw WorkplaceStoreError.duplicatePath
        }
        guard FileManager.default.fileExists(atPath: path) == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }

        let now = Date()
        let workplace = Workplace(
            id: UUID(),
            name: trimmedName,
            path: path,
            selectedRepositoryIDs: selectedRepositories.map(\.id),
            branch: branch,
            createdAt: now,
            updatedAt: now
        )

        let newSyncStates = try selectedRepositories.map { repository in
            RepositorySyncState(
                workplaceID: workplace.id,
                repositoryID: repository.id,
                status: .idle,
                localPath: try Self.repositoryPath(
                    workplacePath: path,
                    repositoryName: repository.repoName
                ),
                lastError: nil,
                lastSyncedAt: nil
            )
        }

        var updatedWorkplaces = workplaces
        updatedWorkplaces.append(workplace)
        var updatedSyncStates = syncStates
        updatedSyncStates.append(contentsOf: newSyncStates)

        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
        return workplace
    }

    func updateRepositories(for workplaceID: UUID, selectedRepositoryIDs: [UUID]) throws {
        guard let index = workplaces.firstIndex(where: { $0.id == workplaceID }) else { return }
        let selectedSet = Set(selectedRepositoryIDs)

        var updatedWorkplaces = workplaces
        updatedWorkplaces[index].selectedRepositoryIDs = selectedRepositoryIDs
        updatedWorkplaces[index].updatedAt = .now
        let updatedSyncStates = syncStates.filter {
            $0.workplaceID != workplaceID || selectedSet.contains($0.repositoryID)
        }

        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    func replaceSyncStates(_ newStates: [RepositorySyncState], for workplaceID: UUID) throws {
        var updatedSyncStates = syncStates.filter { $0.workplaceID != workplaceID }
        updatedSyncStates.append(contentsOf: newStates)
        try persistSyncStates(updatedSyncStates)
    }

    func applyWorkplaceEdit(_ workplace: Workplace, syncStates newStates: [RepositorySyncState]) throws {
        guard let index = workplaces.firstIndex(where: { $0.id == workplace.id }) else { return }

        var updatedWorkplaces = workplaces
        updatedWorkplaces[index] = workplace
        var updatedSyncStates = syncStates.filter { $0.workplaceID != workplace.id }
        updatedSyncStates.append(contentsOf: newStates)

        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    func updateSyncState(_ state: RepositorySyncState) throws {
        guard let index = syncStates.firstIndex(where: {
            $0.workplaceID == state.workplaceID && $0.repositoryID == state.repositoryID
        }) else { return }

        var updatedSyncStates = syncStates
        updatedSyncStates[index] = state
        try persistSyncStates(updatedSyncStates)
    }

    func updateSyncStates(_ states: [RepositorySyncState]) throws {
        guard states.isEmpty == false else { return }
        var indexLookup: [String: Int] = [:]
        var updatedSyncStates = syncStates
        for (index, existing) in updatedSyncStates.enumerated() {
            indexLookup["\(existing.workplaceID)-\(existing.repositoryID)"] = index
        }
        for state in states {
            let key = "\(state.workplaceID)-\(state.repositoryID)"
            guard let index = indexLookup[key] else { continue }
            updatedSyncStates[index] = state
        }
        try persistSyncStates(updatedSyncStates)
    }

    func setSyncStatus(_ status: SyncStatus, for workplaceID: UUID, repositoryIDs: Set<UUID>) throws {
        var changed = false
        var updatedSyncStates = syncStates
        for index in updatedSyncStates.indices where
            updatedSyncStates[index].workplaceID == workplaceID &&
            repositoryIDs.contains(updatedSyncStates[index].repositoryID)
        {
            if updatedSyncStates[index].status != status {
                updatedSyncStates[index].status = status
                changed = true
            }
        }
        guard changed else { return }
        try persistSyncStates(updatedSyncStates)
    }

    func updateBranch(for workplaceID: UUID, branch: String?) throws {
        guard let index = workplaces.firstIndex(where: { $0.id == workplaceID }) else { return }

        var updatedWorkplaces = workplaces
        updatedWorkplaces[index].branch = branch
        updatedWorkplaces[index].updatedAt = .now
        try persistWorkplaces(updatedWorkplaces)
    }

    func removeRepositoryAssociations(repositoryID: UUID) {
        var changed = false
        var updatedWorkplaces = workplaces
        var updatedSyncStates = syncStates

        for i in updatedWorkplaces.indices {
            if updatedWorkplaces[i].selectedRepositoryIDs.contains(repositoryID) {
                updatedWorkplaces[i].selectedRepositoryIDs.removeAll { $0 == repositoryID }
                changed = true
            }
        }
        if updatedSyncStates.contains(where: { $0.repositoryID == repositoryID }) {
            updatedSyncStates.removeAll { $0.repositoryID == repositoryID }
            changed = true
        }
        guard changed else { return }
        do {
            try persist(
                workplaces: updatedWorkplaces,
                syncStates: updatedSyncStates
            )
        } catch {
            workplaceStoreLog.error("event=remove_repository_associations_save_failed reason=\(error.localizedDescription)")
        }
    }

    func deleteWorkplace(_ workplaceID: UUID) throws {
        let updatedWorkplaces = workplaces.filter { $0.id != workplaceID }
        let updatedSyncStates = syncStates.filter { $0.workplaceID != workplaceID }
        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    func refreshFromDisk(rootPath: String) {
        let result = Self.diskRefreshResult(
            workplaces: workplaces,
            syncStates: syncStates,
            rootPath: rootPath
        )
        applyDiskRefreshResult(result)
    }

    func applyDiskRefreshResult(_ result: WorkplaceDiskRefreshResult) {
        guard result.changed else { return }
        do {
            try persist(
                workplaces: result.workplaces,
                syncStates: result.syncStates
            )
        } catch {
            workplaceStoreLog.error("event=disk_refresh_save_failed reason=\(error.localizedDescription)")
        }
    }

    nonisolated static func diskRefreshResult(
        workplaces: [Workplace],
        syncStates: [RepositorySyncState],
        rootPath: String
    ) -> WorkplaceDiskRefreshResult {
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            return WorkplaceDiskRefreshResult(
                workplaces: workplaces,
                syncStates: syncStates,
                changed: false
            )
        }

        let rootURL = URL(fileURLWithPath: trimmedRoot)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return WorkplaceDiskRefreshResult(
                workplaces: workplaces,
                syncStates: syncStates,
                changed: false
            )
        }

        let diskFolders = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        let diskPaths = Set(diskFolders.map { Self.normalizedPath($0.path) })
        var refreshedWorkplaces = workplaces
        var refreshedSyncStates = syncStates
        var changed = false

        // Remove workplaces whose folders no longer exist
        let removed = refreshedWorkplaces.filter { !diskPaths.contains(Self.normalizedPath($0.path)) }
        let removedIDs = Set(removed.map(\.id))
        if !removedIDs.isEmpty {
            refreshedWorkplaces.removeAll { removedIDs.contains($0.id) }
            refreshedSyncStates.removeAll { removedIDs.contains($0.workplaceID) }
            changed = true
        }

        // Scan each workplace for git repos on disk
        for i in refreshedWorkplaces.indices {
            let workplace = refreshedWorkplaces[i]
            // Deduplicate existing sync states by folder name (keep first, remove later)
            var seenNames = Set<String>()
            var duplicateIndices: [Int] = []
            for (idx, state) in refreshedSyncStates.enumerated() {
                guard state.workplaceID == workplace.id else { continue }
                let name = URL(fileURLWithPath: state.localPath).lastPathComponent
                if seenNames.contains(name) {
                    duplicateIndices.append(idx)
                    refreshedWorkplaces[i].selectedRepositoryIDs.removeAll { $0 == state.repositoryID }
                    changed = true
                } else {
                    seenNames.insert(name)
                }
            }
            for idx in duplicateIndices.reversed() {
                refreshedSyncStates.remove(at: idx)
            }

            // Keep missing repositories in the workplace so the UI can still surface retry actions.
            for stateIndex in refreshedSyncStates.indices where
                refreshedSyncStates[stateIndex].workplaceID == workplace.id &&
                !fm.fileExists(atPath: refreshedSyncStates[stateIndex].localPath)
            {
                let normalizedState = normalizedMissingRepositoryState(refreshedSyncStates[stateIndex])
                if normalizedState != refreshedSyncStates[stateIndex] {
                    refreshedSyncStates[stateIndex] = normalizedState
                    changed = true
                }
            }
        }

        return WorkplaceDiskRefreshResult(
            workplaces: refreshedWorkplaces,
            syncStates: refreshedSyncStates,
            changed: changed
        )
    }

    func renameWorkplace(id: UUID, newName: String) throws {
        let trimmedName = try Self.validatedWorkplaceName(newName)

        guard let index = workplaces.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = workplaces[index].path
        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let newPath = try Self.workplacePath(
            rootPath: parentPath,
            name: trimmedName
        )

        let normalizedNewPath = Self.normalizedPath(newPath)
        guard !workplaces.contains(where: { $0.id != id && Self.normalizedPath($0.path) == normalizedNewPath }) else {
            throw WorkplaceStoreError.duplicatePath
        }
        guard normalizedNewPath == Self.normalizedPath(oldPath) ||
                FileManager.default.fileExists(atPath: newPath) == false else {
            throw WorkplaceStoreError.pathAlreadyExistsOnDisk
        }

        // 1. Filesystem rename (most likely to fail)
        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)

        // 2. Compute new state, persist, then apply to in-memory
        //    This ensures in-memory stays consistent if save fails
        var updatedWorkplaces = workplaces
        updatedWorkplaces[index].name = trimmedName
        updatedWorkplaces[index].path = newPath
        updatedWorkplaces[index].updatedAt = .now

        var updatedSyncStates = syncStates
        let oldPrefix = oldPath + "/"
        for i in updatedSyncStates.indices where updatedSyncStates[i].workplaceID == id {
            if updatedSyncStates[i].localPath.hasPrefix(oldPrefix) {
                let remaining = String(updatedSyncStates[i].localPath.dropFirst(oldPrefix.count))
                updatedSyncStates[i].localPath = newPath + "/" + remaining
            }
        }

        do {
            try persist(
                workplaces: updatedWorkplaces,
                syncStates: updatedSyncStates
            )
        } catch {
            // Roll back filesystem rename before rethrowing
            try? FileManager.default.moveItem(atPath: newPath, toPath: oldPath)
            throw error
        }
    }

    nonisolated static func snapshot(
        workplaces: [Workplace],
        syncStates: [RepositorySyncState]
    ) -> WorkplaceStoreSnapshot {
        WorkplaceStoreSnapshot(
            workplaces: workplaces,
            syncStates: syncStates
        )
    }

    nonisolated private static func normalizedMissingRepositoryState(
        _ state: RepositorySyncState
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .failed
        updatedState.lastSyncedAt = nil

        let trimmedError = updatedState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedError.isEmpty {
            updatedState.lastError = WorkplaceRuntimeServiceError.missingLocalRepository.localizedDescription
        }

        return updatedState
    }
}
