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
    case workplaceNotFound

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
        case .workplaceNotFound:
            return "工作区记录已不存在(可能在操作期间被删除),更改未保存"
        }
    }
}

@MainActor
final class WorkplaceStore: ObservableObject {
    @Published private(set) var workplaces: [Workplace]
    @Published private(set) var syncStates: [RepositorySyncState]
    private let fileStore: JSONFileStore

    /// 跨 Store 原子提交(RemoveRepository/updateRootPath)的运行时前提校验入口:
    /// 正确性依赖两个 Store 共用同一数据目录,注入分叉时在提交前拦截而非静默错写。
    var rootDirectoryForCrossStoreCheck: URL { fileStore.rootDirectory }
    private var debouncedSyncStatesWriteTask: Task<Void, Never>?
    private let syncStatesDebounceInterval: Duration

    /// 本次启动是否有持久化文件损坏并被重置为默认值。
    ///
    /// 置空本身是兜底,但下游的启动对账(pruneReferencesToRepositories 等)会把
    /// "空集合"当成真实状态去清理其它文件里的关联数据,造成单个文件损坏级联
    /// 清空另外两个健康文件。调用方应在任一 Store 处于恢复态时跳过破坏性对账。
    private(set) var didRecoverFromCorruptFile = false

    init(fileStore: JSONFileStore, syncStatesDebounceInterval: Duration = .milliseconds(500)) {
        self.fileStore = fileStore
        self.syncStatesDebounceInterval = syncStatesDebounceInterval
        do {
            self.workplaces = try fileStore.loadIfPresent([Workplace].self, from: "workplaces.json", default: [])
        } catch {
            workplaceStoreLog.error("event=load_workplaces_failed reason=\(error.localizedDescription)")
            didRecoverFromCorruptFile = true
            // 逐元素容错抢救(必须在 preserveCorruptFile 之前,后者会改名/复制原文件):
            // 单条坏记录不该让整个工作区列表报废,进而触发下游对账的级联清空。
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                Workplace.self,
                from: "workplaces.json"
            ) {
                self.workplaces = tolerated.values
                workplaceStoreLog.error("event=recovered_partial_workplaces kept=\(tolerated.values.count) dropped=\(tolerated.droppedCount)")
            } else {
                self.workplaces = []
            }
            fileStore.preserveCorruptFile(named: "workplaces.json")
        }
        do {
            self.syncStates = try fileStore.loadIfPresent([RepositorySyncState].self, from: "sync-states.json", default: [])
        } catch {
            workplaceStoreLog.error("event=load_sync_states_failed reason=\(error.localizedDescription)")
            didRecoverFromCorruptFile = true
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                RepositorySyncState.self,
                from: "sync-states.json"
            ) {
                self.syncStates = tolerated.values
                workplaceStoreLog.error("event=recovered_partial_sync_states kept=\(tolerated.values.count) dropped=\(tolerated.droppedCount)")
            } else {
                self.syncStates = []
            }
            fileStore.preserveCorruptFile(named: "sync-states.json")
        }
    }

    /// 启动时用文件系统事实校正 `hasLocalDirectory`。
    ///
    /// 该字段早期是"每次访问读盘"的计算属性,改成持久化 Bool 后老数据里没有这个 key,
    /// 解码一律得到 false;而 false 会禁用详情页的刷新/打开/批量操作等一批入口。
    /// 此前修正只依赖磁盘刷新,根目录不可用(网盘/外置盘未挂载)或启动后立刻切后台时
    /// 可能一直不触发,表现为"仓库一直显示未克隆、按钮全灰"。这里在启动独立校正一次。
    func reconcileHasLocalDirectoryFlags() async {
        // await 前固定快照,探测与回写都以同一份为准:存在性探测会挂起,
        // 期间并发写入可能增删行,若按索引对位(await 前的行号套 await 后的数组)
        // 会把 A 仓库的存在性写到 B 上并落盘。回写按稳定 id 匹配当前最新状态。
        let snapshot = syncStates
        let paths = snapshot.map(\.localPath)
        guard paths.isEmpty == false else { return }
        // 根目录可能在网盘/外置盘上,存在性探测可能阻塞,移出主线程。
        let exists = await Task.detached(priority: .utility) {
            paths.map { FileManager.default.fileExists(atPath: $0) }
        }.value
        let reconciledFlagsById = Dictionary(
            uniqueKeysWithValues: zip(snapshot, exists).map { ($0.id, $1) }
        )

        var updated = syncStates
        var correctedCount = 0
        for index in updated.indices {
            guard let reconciled = reconciledFlagsById[updated[index].id] else { continue }
            guard updated[index].hasLocalDirectory != reconciled else { continue }
            updated[index].hasLocalDirectory = reconciled
            correctedCount += 1
        }
        guard correctedCount > 0 else { return }
        workplaceStoreLog.notice("event=has_local_directory_reconciled corrected=\(correctedCount)")
        // 内存按 key 增量合并,并发的其它行不会被这份快照覆盖;
        // 注意落盘本身仍是整体替换(防抖写盘写全量 sync-states.json),由 flush 兜底。
        updateSyncStates(updated)
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

    /// 防抖持久化:内存立即生效,写盘延后合并。
    /// 注意:此路径**不抛错**——内存赋值与延后写盘都不会失败;唯一的失败点是
    /// 延后的写盘,已由 `flushSyncStates` 记录 `flush_sync_states_failed` 日志兜底,
    /// 不存在静默丢失。因此 replaceSyncStates/updateSyncState(s)/setSyncStatus 均
    /// 不再声明 throws(签名诚实)。
    private func persistSyncStates(_ newSyncStates: [RepositorySyncState]) {
        syncStates = newSyncStates
        scheduleDebouncedSyncStatesPersist()
    }

    private func persistSyncStatesImmediately(_ newSyncStates: [RepositorySyncState]) throws {
        try fileStore.save(newSyncStates, as: "sync-states.json")
        syncStates = newSyncStates
        debouncedSyncStatesWriteTask?.cancel()
        debouncedSyncStatesWriteTask = nil
    }

    private func scheduleDebouncedSyncStatesPersist() {
        debouncedSyncStatesWriteTask?.cancel()
        debouncedSyncStatesWriteTask = Task { [weak self] in
            try? await Task.sleep(for: self?.syncStatesDebounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSyncStates()
        }
    }

    func flushSyncStates() {
        debouncedSyncStatesWriteTask?.cancel()
        debouncedSyncStatesWriteTask = nil
        do {
            try fileStore.save(syncStates, as: "sync-states.json")
        } catch {
            workplaceStoreLog.error("event=flush_sync_states_failed reason=\(error.localizedDescription)")
            scheduleFlushRetry()
        }
    }

    /// 写盘失败(磁盘满/权限异常)后 5s 重试一次:不重试则内存与文件无限期背离,
    /// 崩溃即丢这段时间的全部状态变更。仍失败则放弃(下个变更事件会再次触发写)。
    private func scheduleFlushRetry() {
        guard debouncedSyncStatesWriteTask == nil else { return }
        debouncedSyncStatesWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.debouncedSyncStatesWriteTask = nil
            self?.flushSyncStates()
        }
    }

    private func persist(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) throws {
        let documents = try persistenceDocuments(
            workplaces: newWorkplaces,
            syncStates: newSyncStates
        )
        try fileStore.save(documents)
        applyPersistedState(workplaces: newWorkplaces, syncStates: newSyncStates)
    }

    /// 预生成 workplaces/sync-states 两份文档(不写盘)。
    /// 供跨 Store 的原子提交组合使用:调用方(如 RepositoryStore.removeRepository、
    /// SettingsStore.updateRootPath)把这些文档和自己的文档合并后一次
    /// `JSONFileStore.save(documents)` 落盘,失败整体回滚,避免多文件两阶段写的中间态。
    /// 注意:要求双方共用同一个数据目录(生产环境由 RootSplitView 注入同一 fileStore)。
    func persistenceDocuments(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) throws -> [JSONFileStoreDocument] {
        try [
            fileStore.document(for: newWorkplaces, as: "workplaces.json"),
            fileStore.document(for: newSyncStates, as: "sync-states.json"),
        ]
    }

    /// 文档已由调用方原子提交成功后,把状态应用到内存(取消待执行的防抖写盘,
    /// 防止旧快照稍后覆盖新状态)。与 `persistenceDocuments` 配对使用。
    func applyPersistedState(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) {
        debouncedSyncStatesWriteTask?.cancel()
        debouncedSyncStatesWriteTask = nil
        workplaces = newWorkplaces
        syncStates = newSyncStates
    }

    private func mutateWorkplace(
        _ workplaceID: UUID,
        update: (inout Workplace) -> Bool
    ) throws {
        // 记录找不到不能静默 return:调用方(置顶/归档等)需要知道更改没生效。
        guard let index = workplaces.firstIndex(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }

        var updatedWorkplaces = workplaces
        let changed = update(&updatedWorkplaces[index])
        guard changed else { return }

        updatedWorkplaces[index].updatedAt = .now
        try persistWorkplaces(updatedWorkplaces)
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

    /// 更新工作区选中的仓库集合。
    /// `repositories` 必须显式传入(不给默认值):缺省空数组会静默跳过
    /// 新勾选仓库的 sync state 生成,造成"选了但没有状态"的隐性数据缺失。
    func updateRepositories(
        for workplaceID: UUID,
        selectedRepositoryIDs: [UUID],
        repositories: [RepositoryConfig]
    ) throws {
        // 记录找不到不能静默 return:勾选的仓库集合没生效必须让调用方知道。
        guard let index = workplaces.firstIndex(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }
        let selectedSet = Set(selectedRepositoryIDs)
        let workplacePath = workplaces[index].path

        var updatedWorkplaces = workplaces
        updatedWorkplaces[index].selectedRepositoryIDs = selectedRepositoryIDs
        updatedWorkplaces[index].updatedAt = .now
        updatedWorkplaces[index].pinnedRepositoryIDs = Self.sanitizedPinnedIDs(
            updatedWorkplaces[index].pinnedRepositoryIDs,
            against: selectedRepositoryIDs
        )

        var updatedSyncStates = syncStates.filter {
            $0.workplaceID != workplaceID || selectedSet.contains($0.repositoryID)
        }

        let existingSyncStateRepoIDs = Set(
            syncStates.filter { $0.workplaceID == workplaceID }.map(\.repositoryID)
        )
        let newlyAddedIDs = selectedSet.subtracting(existingSyncStateRepoIDs)
        if !newlyAddedIDs.isEmpty {
            // 导入的备份 JSON 理论上可能含重复 id,uniqueKeysWithValues 会直接 trap;
            // 循环构建时后者覆盖前者即可。
            var reposByID = Dictionary<UUID, RepositoryConfig>(minimumCapacity: repositories.count)
            for repository in repositories {
                reposByID[repository.id] = repository
            }
            for repoID in newlyAddedIDs {
                // 仓库名来自用户配置,必须经 LocalPathSafety 校验后拼路径;
                // 校验失败(如名称含路径分隔符)或配置缺失时跳过,不做绕过安全防线的裸拼接。
                guard let repoName = reposByID[repoID]?.repoName,
                      let localPath = try? Self.repositoryPath(
                          workplacePath: workplacePath,
                          repositoryName: repoName
                      ) else {
                    continue
                }
                updatedSyncStates.append(RepositorySyncState(
                    workplaceID: workplaceID,
                    repositoryID: repoID,
                    status: .idle,
                    localPath: localPath,
                    lastError: nil,
                    lastSyncedAt: nil
                ))
            }
        }

        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    /// 启动期对账:为"工作区已选中但 sync state 丢失"的仓库补建 idle 状态
    /// (如 sync-states.json 曾损坏被重置),避免工作区永久不可用。
    /// 仓库配置缺失或名称校验失败时跳过该仓库,留待用户编辑时生成。
    func backfillMissingSyncStates(repositories: [RepositoryConfig]) throws {
        var reposByID = Dictionary<UUID, RepositoryConfig>(minimumCapacity: repositories.count)
        for repository in repositories {
            reposByID[repository.id] = repository
        }

        var updatedSyncStates = syncStates
        var changed = false
        for workplace in workplaces {
            let existingRepoIDs = Set(
                syncStates.filter { $0.workplaceID == workplace.id }.map(\.repositoryID)
            )
            for repositoryID in workplace.selectedRepositoryIDs where existingRepoIDs.contains(repositoryID) == false {
                guard let repository = reposByID[repositoryID],
                      let localPath = try? Self.repositoryPath(
                          workplacePath: workplace.path,
                          repositoryName: repository.repoName
                      ) else {
                    continue
                }
                updatedSyncStates.append(RepositorySyncState(
                    workplaceID: workplace.id,
                    repositoryID: repositoryID,
                    status: .idle,
                    localPath: localPath,
                    lastError: nil,
                    lastSyncedAt: nil
                ))
                changed = true
            }
        }
        guard changed else { return }
        try persistSyncStatesImmediately(updatedSyncStates)
    }

    /// 启动期对账:清理孤儿引用
    /// (跨 Store 两阶段持久化的中间失败窗口会留下:仓库已删,但工作区
    /// 的 selectedRepositoryIDs / pinnedRepositoryIDs / sync states 还引用着它)。
    /// 同时清理 workplaceID 已不在 workplaces 集合内的 sync state——
    /// 此类记录没有任何 UI 入口,不清理会在 sync-states.json 里永久累积。
    func pruneReferencesToRepositories(validRepositoryIDs: Set<UUID>) throws {
        // 守卫:传入的有效集合为空、但内存里明明还引用着仓库时,说明是上游数据异常
        // (持久化损坏 / 加载失败)而非"用户真的把仓库都删了"。此时直接放弃,避免把
        // 健康的工作区关联数据一并清空。
        let referencedIDs = Set(workplaces.flatMap(\ .selectedRepositoryIDs))
            .union(Set(workplaces.flatMap(\ .pinnedRepositoryIDs)))
            .union(Set(syncStates.map(\ .repositoryID)))
        if validRepositoryIDs.isEmpty && referencedIDs.isEmpty == false {
            workplaceStoreLog.error("event=prune_aborted reason=empty_valid_repository_ids_with_existing_references")
            return
        }

        var changed = false
        var updatedWorkplaces = workplaces

        for i in updatedWorkplaces.indices {
            let prunedSelection = updatedWorkplaces[i].selectedRepositoryIDs.filter { validRepositoryIDs.contains($0) }
            let prunedPinned = updatedWorkplaces[i].pinnedRepositoryIDs.filter { validRepositoryIDs.contains($0) }
            if prunedSelection != updatedWorkplaces[i].selectedRepositoryIDs ||
                prunedPinned != updatedWorkplaces[i].pinnedRepositoryIDs {
                updatedWorkplaces[i].selectedRepositoryIDs = prunedSelection
                updatedWorkplaces[i].pinnedRepositoryIDs = prunedPinned
                updatedWorkplaces[i].updatedAt = .now
                changed = true
            }
        }

        let validWorkplaceIDs = Set(workplaces.map(\.id))
        var updatedSyncStates = syncStates
        let orphanedSyncStateCount = updatedSyncStates.filter {
            validRepositoryIDs.contains($0.repositoryID) == false ||
                validWorkplaceIDs.contains($0.workplaceID) == false
        }.count
        let syncStatesChanged = orphanedSyncStateCount > 0
        if syncStatesChanged {
            updatedSyncStates.removeAll {
                validRepositoryIDs.contains($0.repositoryID) == false ||
                    validWorkplaceIDs.contains($0.workplaceID) == false
            }
        }

        guard changed || syncStatesChanged else { return }
        if syncStatesChanged {
            try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
        } else {
            try persistWorkplaces(updatedWorkplaces)
        }
    }

    func setPinned(_ isPinned: Bool, for workplaceID: UUID) throws {
        try mutateWorkplace(workplaceID) { workplace in
            guard workplace.isPinned != isPinned else { return false }
            workplace.isPinned = isPinned
            return true
        }
    }

    nonisolated static func sanitizedPinnedIDs(
        _ pinned: [UUID],
        against selected: [UUID]
    ) -> [UUID] {
        let selectedSet = Set(selected)
        return pinned.filter { selectedSet.contains($0) }
    }

    func setRepositoryPinned(
        _ isPinned: Bool,
        repositoryID: UUID,
        in workplaceID: UUID
    ) throws {
        try mutateWorkplace(workplaceID) { workplace in
            guard workplace.selectedRepositoryIDs.contains(repositoryID) else { return false }
            var current = workplace.pinnedRepositoryIDs
            if isPinned {
                guard current.contains(repositoryID) == false else { return false }
                current.append(repositoryID)
            } else {
                guard current.contains(repositoryID) else { return false }
                current.removeAll { $0 == repositoryID }
            }
            workplace.pinnedRepositoryIDs = current
            return true
        }
    }

    func setArchived(_ isArchived: Bool, for workplaceID: UUID) throws {
        try mutateWorkplace(workplaceID) { workplace in
            guard workplace.isArchived != isArchived else { return false }
            workplace.isArchived = isArchived
            return true
        }
    }

    func replaceSyncStates(_ newStates: [RepositorySyncState], for workplaceID: UUID) {
        var updatedSyncStates = syncStates.filter { $0.workplaceID != workplaceID }
        updatedSyncStates.append(contentsOf: newStates)
        persistSyncStates(updatedSyncStates)
    }

    func applyWorkplaceEdit(_ workplace: Workplace, syncStates newStates: [RepositorySyncState]) throws {
        // 记录找不到不能静默 return:编辑流程(改名/移动/克隆/切分支)已经在磁盘上
        // 做完实际工作,若此处吞掉,所有成果与记录脱节且用户看到"保存成功"。
        guard let index = workplaces.firstIndex(where: { $0.id == workplace.id }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }

        var updatedWorkplaces = workplaces
        var sanitizedWorkplace = workplace
        sanitizedWorkplace.pinnedRepositoryIDs = Self.sanitizedPinnedIDs(
            sanitizedWorkplace.pinnedRepositoryIDs,
            against: sanitizedWorkplace.selectedRepositoryIDs
        )
        sanitizedWorkplace.updatedAt = .now
        updatedWorkplaces[index] = sanitizedWorkplace
        var updatedSyncStates = syncStates.filter { $0.workplaceID != workplace.id }
        updatedSyncStates.append(contentsOf: newStates)

        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    /// 单行更新:行仍在则覆盖;行在 await 窗口内被去重/prune 掉但工作区仍在且仓库
    /// 仍被选中,则补录(与 `updateSyncStates` 的补录语义一致),否则克隆/pull 的
    /// 结果会永不落库。工作区记录已不存在时不补录(孤儿行没有任何 UI 入口),
    /// 只留痕——本方法与批量版本一样不抛错(持久化走防抖写盘,不失败)。
    func updateSyncState(_ state: RepositorySyncState) {
        var updatedSyncStates = syncStates
        if let index = updatedSyncStates.firstIndex(where: {
            $0.workplaceID == state.workplaceID && $0.repositoryID == state.repositoryID
        }) {
            updatedSyncStates[index] = state
            persistSyncStates(updatedSyncStates)
            return
        }
        guard let workplace = workplaces.first(where: { $0.id == state.workplaceID }),
              workplace.selectedRepositoryIDs.contains(state.repositoryID) else {
            workplaceStoreLog.error(
                "event=update_sync_state_dropped reason=workplace_missing workplace_id=\(state.workplaceID) repository_id=\(state.repositoryID)"
            )
            return
        }
        updatedSyncStates.append(state)
        persistSyncStates(updatedSyncStates)
    }

    func updateSyncStates(_ states: [RepositorySyncState]) {
        guard states.isEmpty == false else { return }
        var indexLookup: [String: Int] = [:]
        var updatedSyncStates = syncStates
        for (index, existing) in updatedSyncStates.enumerated() {
            indexLookup["\(existing.workplaceID)-\(existing.repositoryID)"] = index
        }
        for state in states {
            let key = "\(state.workplaceID)-\(state.repositoryID)"
            if let index = indexLookup[key] {
                updatedSyncStates[index] = state
                continue
            }
            // 未知 key 不能静默跳过:克隆完成走增量更新时,若该仓库的 state 行
            // 在 await 期间被去重/prune 掉,静默跳过会让克隆结果不落库,
            // UI 上该仓库永远没有状态行。仅补录仍属于当前选中仓库的行,
            // 避免把已被移出工作区的仓库状态"复活"。
            guard let workplace = workplaces.first(where: { $0.id == state.workplaceID }),
                  workplace.selectedRepositoryIDs.contains(state.repositoryID) else {
                continue
            }
            updatedSyncStates.append(state)
            indexLookup[key] = updatedSyncStates.count - 1
        }
        persistSyncStates(updatedSyncStates)
    }

    func setSyncStatus(_ status: SyncStatus, for workplaceID: UUID, repositoryIDs: Set<UUID>) {
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
        persistSyncStates(updatedSyncStates)
    }

    /// 清理"失败但本地目录仍在"的展示态(实际状态已在外部被修复,如在命令行处理完冲突)。
    ///
    /// 存在性探测可能落在网盘/外置盘上,单次 `fileExists` 就能阻塞数秒到数分钟,
    /// 必须移出主线程(同 `reconcileHasLocalDirectoryFlags`)。探测结果按稳定 id
    /// 回填到 await 之后的当前最新状态,不按 await 前的行号对位——探测挂起期间
    /// 并发写入可能增删行。
    /// 保持同步签名(调用方 RootSplitView 的回调是同步闭包):内部起 Task 承载
    /// 探测与回填,本方法立即返回,不在主线程等待任何磁盘 I/O。
    func clearFailedStatusesWhereDirectoryExists(workplaceID: UUID) {
        let candidates = syncStates.filter { state in
            state.workplaceID == workplaceID && state.status == .failed
        }
        guard candidates.isEmpty == false else { return }
        let candidateIDs = candidates.map(\.id)
        let paths = candidates.map(\.localPath)
        Task { [weak self] in
            let existsFlags = await Task.detached(priority: .utility) {
                paths.map { FileManager.default.fileExists(atPath: $0) }
            }.value
            guard let self else { return }
            let aliveIDs = Set(
                zip(candidateIDs, existsFlags)
                    .filter { $0.1 }
                    .map { $0.0 }
            )
            let cleared = self.syncStates
                .filter { state in
                    state.workplaceID == workplaceID
                        && state.status == .failed
                        && aliveIDs.contains(state.id)
                }
                .map { state -> RepositorySyncState in
                    var updated = state
                    updated.status = .success
                    updated.lastError = nil
                    return updated
                }
            guard cleared.isEmpty == false else { return }
            self.updateSyncStates(cleared)
        }
    }

    func updateBranch(for workplaceID: UUID, branch: String?) throws {
        // 记录找不到不能静默 return:分支更改没生效必须让调用方知道。
        guard let index = workplaces.firstIndex(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }

        var updatedWorkplaces = workplaces
        updatedWorkplaces[index].branch = branch
        updatedWorkplaces[index].updatedAt = .now
        try persistWorkplaces(updatedWorkplaces)
    }

    /// 计算"删除某仓库所有工作区关联"后的目标状态(不写盘);无变化时返回 nil。
    /// 供 RepositoryStore.removeRepository 把 repositories.json 与工作区文档
    /// 合并为一次原子提交,消除两阶段写的中间失败窗口。
    func stateAfterRemovingRepositoryAssociations(
        repositoryID: UUID
    ) -> (workplaces: [Workplace], syncStates: [RepositorySyncState])? {
        var changed = false
        var updatedWorkplaces = workplaces
        var updatedSyncStates = syncStates

        for i in updatedWorkplaces.indices {
            if updatedWorkplaces[i].selectedRepositoryIDs.contains(repositoryID) {
                updatedWorkplaces[i].selectedRepositoryIDs.removeAll { $0 == repositoryID }
                updatedWorkplaces[i].pinnedRepositoryIDs = Self.sanitizedPinnedIDs(
                    updatedWorkplaces[i].pinnedRepositoryIDs,
                    against: updatedWorkplaces[i].selectedRepositoryIDs
                )
                updatedWorkplaces[i].updatedAt = .now
                changed = true
            }
        }
        if updatedSyncStates.contains(where: { $0.repositoryID == repositoryID }) {
            updatedSyncStates.removeAll { $0.repositoryID == repositoryID }
            changed = true
        }
        guard changed else { return nil }
        return (updatedWorkplaces, updatedSyncStates)
    }

    func deleteWorkplace(_ workplaceID: UUID) throws {
        let updatedWorkplaces = workplaces.filter { $0.id != workplaceID }
        let updatedSyncStates = syncStates.filter { $0.workplaceID != workplaceID }
        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    /// 计算换根后的目标状态与迁移条数(不写盘);无需迁移时返回 nil。
    /// 供 SettingsStore.updateRootPath 把 settings.json 与工作区文档合并为
    /// 一次原子提交:换根"先迁记录再改设置"两步分开写盘,中间失败会留下
    /// "记录指向新根而设置仍是旧根"的不一致,下次磁盘刷新会把部分工作区
    /// 判为 missing 永久删除。
    func rebasePlan(
        fromRoot oldRoot: String,
        toRoot newRoot: String
    ) -> (workplaces: [Workplace], syncStates: [RepositorySyncState], rebasedCount: Int)? {
        let normalizedOldRoot = Self.normalizedPath(oldRoot)
        let normalizedNewRoot = Self.normalizedPath(newRoot)
        guard normalizedOldRoot.isEmpty == false,
              normalizedNewRoot.isEmpty == false,
              normalizedOldRoot != normalizedNewRoot else { return nil }

        var rebasedWorkplaces = workplaces
        // 旧路径 → 新路径,只含真正被迁移的工作区。同步态跟随所属工作区迁移,
        // 而不是各自对旧根求相对路径,否则嵌套根时已在新根下的工作区
        // 其同步态会被二次嵌套。
        var rebasedPaths: [UUID: (oldPath: String, newPath: String)] = [:]
        for index in rebasedWorkplaces.indices {
            let currentPath = Self.normalizedPath(rebasedWorkplaces[index].path)
            guard let relativePath = Self.relativePath(of: currentPath, within: normalizedOldRoot) else { continue }
            guard Self.relativePath(of: currentPath, within: normalizedNewRoot) == nil else { continue }
            let newPath = normalizedNewRoot + "/" + relativePath
            rebasedWorkplaces[index].path = newPath
            rebasedWorkplaces[index].updatedAt = .now
            rebasedPaths[rebasedWorkplaces[index].id] = (currentPath, newPath)
        }
        guard rebasedPaths.isEmpty == false else { return nil }

        var rebasedSyncStates = syncStates
        for index in rebasedSyncStates.indices {
            guard let paths = rebasedPaths[rebasedSyncStates[index].workplaceID] else { continue }
            guard let relativePath = Self.relativePath(
                of: rebasedSyncStates[index].localPath,
                within: paths.oldPath
            ) else { continue }
            rebasedSyncStates[index].localPath = paths.newPath + "/" + relativePath
        }

        return (rebasedWorkplaces, rebasedSyncStates, rebasedPaths.count)
    }

    /// 返回 path 相对 root 的相对路径;path 不在 root 下、或等于 root 本身时返回 nil。
    nonisolated private static func relativePath(of path: String, within root: String) -> String? {
        let normalizedPath = Self.normalizedPath(path)
        guard LocalPathSafety.isWithinDirectory(normalizedPath, rootPath: root) else { return nil }
        guard normalizedPath != root else { return nil }
        return String(normalizedPath.dropFirst(root.count + 1))
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

    /// 用磁盘事实校正 workplaces/syncStates 的展示态(纯函数,便于测试)。
    ///
    /// - Parameter lockedPathKeys: `RepositoryOperationLock.inFlightPathKeys()` 的快照
    ///   (canonical key)。命中豁免的路径**不做任何破坏性改写**:创建/改名/克隆/删除等
    ///   长操作期间,"记录存在、目录暂缺"是正常中间态(记录先落库、目录后创建,或整树
    ///   移动中),按这一刻的陈旧磁盘视图删除记录会造成不可逆的数据脱节——刷新结果
    ///   等值重试机制也救不回来。
    nonisolated static func diskRefreshResult(
        workplaces: [Workplace],
        syncStates: [RepositorySyncState],
        rootPath: String,
        lockedPathKeys: Set<String> = []
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

        // Safety: if disk shows zero folders but we have workplaces, the root may be
        // temporarily unavailable (e.g. network volume). Skip removal to avoid data loss.
        if diskPaths.isEmpty && !workplaces.isEmpty {
            return WorkplaceDiskRefreshResult(
                workplaces: workplaces,
                syncStates: syncStates,
                changed: false
            )
        }

        var refreshedWorkplaces = workplaces
        var refreshedSyncStates = syncStates
        var changed = false

        // Remove workplaces whose folders no longer exist
        // (持锁/有瞬态进行中状态的长操作豁免:见函数注释)
        let missing = refreshedWorkplaces.filter { workplace in
            if diskPaths.contains(Self.normalizedPath(workplace.path)) { return false }
            return !Self.isWorkplaceOperationInFlight(
                workplace,
                syncStates: refreshedSyncStates,
                lockedPathKeys: lockedPathKeys
            )
        }
        // Safety: when *every* workplace is missing at once, that is far more likely a
        // configuration change (root path switched) or an unavailable volume than N deliberate
        // deletions. Skip the cleanup so one refresh can never wipe the whole library.
        let allMissing = !refreshedWorkplaces.isEmpty && missing.count == refreshedWorkplaces.count
        let removedIDs = allMissing ? Set<UUID>() : Set(missing.map(\.id))
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
                    refreshedWorkplaces[i].pinnedRepositoryIDs = Self.sanitizedPinnedIDs(
                        refreshedWorkplaces[i].pinnedRepositoryIDs,
                        against: refreshedWorkplaces[i].selectedRepositoryIDs
                    )
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
                refreshedSyncStates[stateIndex].workplaceID == workplace.id
            {
                let exists = fm.fileExists(atPath: refreshedSyncStates[stateIndex].localPath)
                if !exists {
                    // 瞬态进行中状态(.cloning/.pulling/.switching/.removing)只可能由
                    // 本进程内活跃操作写入:此刻目录"缺失"多半是操作还没落位(或正在
                    // 整树移动),不是用户删了仓库——按陈旧磁盘视图改写会把进行中的行
                    // 打成"本地仓库缺失"的假失败。持锁路径同理豁免(见函数注释)。
                    let state = refreshedSyncStates[stateIndex]
                    if Self.isTransientSyncStatus(state.status)
                        || lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: state.localPath))
                        || lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: workplace.path))
                    {
                        continue
                    }
                    let normalizedState = Self.normalizedMissingRepositoryState(state)
                    if normalizedState != refreshedSyncStates[stateIndex] {
                        refreshedSyncStates[stateIndex] = normalizedState
                        changed = true
                    }
                } else if !refreshedSyncStates[stateIndex].hasLocalDirectory {
                    refreshedSyncStates[stateIndex].hasLocalDirectory = true
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

        // 记录找不到不能静默 return:改名没生效必须让调用方知道
        // (FS 层错误仍走下面各自的 throw,不在此列)。
        guard let index = workplaces.firstIndex(where: { $0.id == id }) else {
            throw WorkplaceStoreError.workplaceNotFound
        }
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
        let normalizedOldPrefix = Self.normalizedPath(oldPath) + "/"
        for i in updatedSyncStates.indices where updatedSyncStates[i].workplaceID == id {
            let normalizedLocalPath = Self.normalizedPath(updatedSyncStates[i].localPath)
            if normalizedLocalPath.hasPrefix(normalizedOldPrefix) {
                let remaining = String(normalizedLocalPath.dropFirst(normalizedOldPrefix.count))
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
            do {
                try FileManager.default.moveItem(atPath: newPath, toPath: oldPath)
            } catch let rollbackError {
                workplaceStoreLog.fault("event=rename_rollback_failed from=\(newPath) to=\(oldPath) reason=\(rollbackError.localizedDescription)")
                // Filesystem has new name but persist failed — best-effort persist to avoid data loss
                try? persistWorkplaces(updatedWorkplaces)
                persistSyncStates(updatedSyncStates)
            }
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

    /// 该同步状态是否属于"本进程内正在进行的长操作"(瞬态)。
    /// 瞬态只由活跃操作写入,重启解码时已归位为 .idle(见 RepositorySyncState.init(from:)),
    /// 因此瞬态可以安全地当作"进行中"信号使用。
    nonisolated private static func isTransientSyncStatus(_ status: SyncStatus) -> Bool {
        switch status {
        case .cloning, .pulling, .switching, .removing:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    /// 工作区级豁免:目录本身持锁,或其任一仓库路径持锁/处于瞬态(说明创建、改名、
    /// 补克隆等长操作正在进行),本次磁盘刷新就不得因"目录暂缺"删除该工作区记录。
    ///
    /// 锁快照为空**不能**否定豁免:瞬态只由本进程内活跃操作写入(重启解码已归位
    /// .idle),长操作在两次持锁段之间(如整树移动完成与下一个仓库级锁之间)存在
    /// 无锁 await 窗口,此时瞬态行是唯一可靠的"进行中"信号,必须照样豁免。
    nonisolated private static func isWorkplaceOperationInFlight(
        _ workplace: Workplace,
        syncStates: [RepositorySyncState],
        lockedPathKeys: Set<String>
    ) -> Bool {
        if lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: workplace.path)) {
            return true
        }
        for state in syncStates where state.workplaceID == workplace.id {
            if isTransientSyncStatus(state.status) { return true }
            if lockedPathKeys.contains(LocalPathSafety.canonicalLockKey(for: state.localPath)) {
                return true
            }
        }
        return false
    }

    nonisolated private static func normalizedMissingRepositoryState(
        _ state: RepositorySyncState
    ) -> RepositorySyncState {
        var updatedState = state
        updatedState.status = .failed
        updatedState.lastSyncedAt = nil
        updatedState.hasLocalDirectory = false

        let trimmedError = updatedState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedError.isEmpty {
            updatedState.lastError = WorkplaceRuntimeServiceError.missingLocalRepository.localizedDescription
        }

        return updatedState
    }
}
