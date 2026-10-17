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
    /// 删除场景专用:目录已删成功后记录恰在此前被并发路径移除——目标已达成,不能沿用
    /// workplaceNotFound 的"更改未保存"文案误导用户。
    case workplaceAlreadyRemoved

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
        case .workplaceAlreadyRemoved:
            return "该工作区已不存在(可能在操作期间被删除),无需再次删除"
        }
    }
}

@MainActor
final class WorkplaceStore: ObservableObject {
    @Published private(set) var workplaces: [Workplace]
    @Published private(set) var syncStates: [RepositorySyncState]
    private let fileStore: JSONFileStore

    /// 跨 Store 原子提交(removeRepository / updateRootPath)的前提校验入口:正确性依赖两个 Store
    /// 共用同一数据目录,注入分叉时在提交前拦截而非静默错写。
    var rootDirectoryForCrossStoreCheck: URL { fileStore.rootDirectory }
    private var debouncedSyncStatesWriteTask: Task<Void, Never>?
    private let syncStatesDebounceInterval: Duration
    /// sync-states 防抖写的重试预算:只在 sync-states 自身写成功时归零——workplaces 单文件写成功与它无关,
    /// 共用一个预算会让"交替写两类数据"把重试永远重置、永不收敛。
    private(set) var flushRetryCount = 0
    /// 重试上限:超过即放弃,避免"固定间隔同步写 + 一条 error 日志"永不收敛。
    static let maxFlushRetryCount = 5
    private let flushRetryBaseSeconds: Int

    /// 本次启动是否有持久化文件损坏并被重置为默认值。置空本身是兜底,但下游启动对账会把"空集合"当成
    /// 真实状态去清理其它文件的关联数据 → 单文件损坏级联清空另外两个健康文件;恢复态须跳过破坏性对账。
    private(set) var didRecoverFromCorruptFile = false

    init(
        fileStore: JSONFileStore,
        syncStatesDebounceInterval: Duration = .milliseconds(500),
        flushRetryBaseSeconds: Int = 5
    ) {
        self.fileStore = fileStore
        self.syncStatesDebounceInterval = syncStatesDebounceInterval
        self.flushRetryBaseSeconds = flushRetryBaseSeconds
        // 抢救出的子集必须立即回写(preserveCorruptFile 已把原文件改名拿走):只留内存而本会话再无写盘时文件
        // 保持缺失,下次启动直接返回空列表、didRecoverFromCorruptFile 也是 false,用户看不到任何异常提示。
        var salvagedSubsetNeedsRewrite = false
        do {
            self.workplaces = WorkplaceStore.deduplicatedWorkplaces(
                try fileStore.loadIfPresent([Workplace].self, from: "workplaces.json", default: [])
            )
        } catch {
            workplaceStoreLog.error("event=load_workplaces_failed reason=\(error.localizedDescription, privacy: .public)")
            didRecoverFromCorruptFile = true
            // 逐元素容错抢救(必须在 preserveCorruptFile 之前,后者会改名/复制原文件):
            // 单条坏记录不该让整个工作区列表报废,进而触发下游对账的级联清空。
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                Workplace.self,
                from: "workplaces.json"
            ) {
                self.workplaces = WorkplaceStore.deduplicatedWorkplaces(tolerated.values)
                workplaceStoreLog.error("event=recovered_partial_workplaces kept=\(tolerated.values.count, privacy: .public) dropped=\(tolerated.droppedCount, privacy: .public)")
                salvagedSubsetNeedsRewrite = true
            } else {
                self.workplaces = []
            }
            fileStore.preserveCorruptFile(named: "workplaces.json")
        }
        do {
            self.syncStates = WorkplaceStore.deduplicatedSyncStates(
                try fileStore.loadIfPresent([RepositorySyncState].self, from: "sync-states.json", default: [])
            )
        } catch {
            workplaceStoreLog.error("event=load_sync_states_failed reason=\(error.localizedDescription, privacy: .public)")
            didRecoverFromCorruptFile = true
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                RepositorySyncState.self,
                from: "sync-states.json"
            ) {
                self.syncStates = WorkplaceStore.deduplicatedSyncStates(tolerated.values)
                workplaceStoreLog.error("event=recovered_partial_sync_states kept=\(tolerated.values.count, privacy: .public) dropped=\(tolerated.droppedCount, privacy: .public)")
                salvagedSubsetNeedsRewrite = true
            } else {
                self.syncStates = []
            }
            fileStore.preserveCorruptFile(named: "sync-states.json")
        }
        // 抢救出的子集立即回写(两份文档一次原子提交,保持跨文件一致)。
        // 失败只留痕:init 不该因写盘失败让 App 起不来,数据仍可从 .corrupt- 副本取回。
        if salvagedSubsetNeedsRewrite {
            do {
                try persist(workplaces: workplaces, syncStates: syncStates)
            } catch {
                workplaceStoreLog.error(
                    "event=salvaged_subset_rewrite_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// 按 `id`(workplaceID-repositoryID 组合键)去重保留首条。加载入口必须收敛:sync-states.json 可能因
    /// 手工编辑或容错解码混入重复行,而下游按 id 建 `Dictionary(uniqueKeysWithValues:)` 遇重复键会 trap。
    nonisolated static func deduplicatedSyncStates(_ states: [RepositorySyncState]) -> [RepositorySyncState] {
        var seenKeys = Set<String>()
        return states.filter { seenKeys.insert($0.id).inserted }
    }

    /// 按 `id` 去重保留首条(同理):重复 id 会让 `mutateWorkplace` 只命中首条、第二条永不可达,
    /// 且按 id 对位的回写/并发合并会把两行当成同一工作区。
    nonisolated static func deduplicatedWorkplaces(_ workplaces: [Workplace]) -> [Workplace] {
        var seenIDs = Set<UUID>()
        return workplaces.filter { seenIDs.insert($0.id).inserted }
    }

    /// 启动时用文件系统事实校正 `hasLocalDirectory`:老数据没有这个 key、解码一律得到 false,而 false 会禁用
    /// 详情页的刷新/打开/批量操作入口;只靠磁盘刷新时,根目录未挂载等场景可能一直不触发,故启动独立校正一次。
    func reconcileHasLocalDirectoryFlags() async {
        // await 前固定快照,回写按稳定 id 匹配当前最新状态:探测会挂起,期间并发写入可能增删行,
        // 若按 await 前的行号套 await 后的数组,会把 A 仓库的存在性写到 B 上并落盘。
        let snapshot = syncStates
        let paths = snapshot.map(\.localPath)
        guard paths.isEmpty == false else { return }
        // 根目录可能在网盘/外置盘上,存在性探测会阻塞主线程,移出主线程。
        let exists = await Task.detached(priority: .utility) {
            paths.map { FileManager.default.fileExists(atPath: $0) }
        }.value
        // 不用 uniqueKeysWithValues:混入重复组合键就 precondition trap(启动 .task 每次必跑,用户无自救);
        // 循环构建、重复键后者覆盖前者即可。
        var reconciledFlagsById = [String: Bool](minimumCapacity: snapshot.count)
        for (state, existsFlag) in zip(snapshot, exists) {
            reconciledFlagsById[state.id] = existsFlag
        }

        var updated = syncStates
        var correctedCount = 0
        for index in updated.indices {
            guard let reconciled = reconciledFlagsById[updated[index].id] else { continue }
            guard updated[index].hasLocalDirectory != reconciled else { continue }
            updated[index].hasLocalDirectory = reconciled
            correctedCount += 1
        }
        guard correctedCount > 0 else { return }
        workplaceStoreLog.notice("event=has_local_directory_reconciled corrected=\(correctedCount, privacy: .public)")
        // 内存按 key 增量合并,并发的其它行不会被这份快照覆盖;落盘仍是整体替换(防抖写全量),由 flush 兜底。
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

    /// 内存先行、同步写盘:写盘成功才改内存,失败直接抛给调用方回滚。刻意保持同步语义——跨 Store 原子
    /// 提交、防抖与失败重试都依赖"写盘与状态更新在同一主线程顺序发生",改到后台队列会牵动失败回滚时序。
    private func persistWorkplaces(_ newWorkplaces: [Workplace]) throws {
        try fileStore.save(newWorkplaces, as: "workplaces.json")
        workplaces = newWorkplaces
        // 不重置 flushRetryCount:那是 sync-states 防抖写的重试预算,与本文件的写成功与否无关。
    }

    /// 防抖持久化:内存立即生效,写盘延后合并。此路径**不抛错**——唯一失败点是延后的写盘,已由
    /// `flushSyncStates` 记录 `flush_sync_states_failed` 兜底,不存在静默丢失,故调用方不必声明 throws。
    private func persistSyncStates(_ newSyncStates: [RepositorySyncState]) {
        syncStates = newSyncStates
        flushRetryCount = 0
        scheduleDebouncedSyncStatesPersist()
    }

    private func persistSyncStatesImmediately(_ newSyncStates: [RepositorySyncState]) throws {
        try fileStore.save(newSyncStates, as: "sync-states.json")
        syncStates = newSyncStates
        flushRetryCount = 0
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
            flushRetryCount = 0
        } catch {
            workplaceStoreLog.error("event=flush_sync_states_failed reason=\(error.localizedDescription, privacy: .public)")
            scheduleFlushRetry()
        }
    }

    /// 写盘失败(磁盘满/权限异常)后按 base×次数 退避重试(5s→10s→15s…),最多 `maxFlushRetryCount` 次:
    /// 不重试则内存与文件无限期背离、崩溃即丢掉这段时间的全部变更,无限重试则每 5s 一次同步写永不收敛。
    private func scheduleFlushRetry() {
        guard debouncedSyncStatesWriteTask == nil else { return }
        guard flushRetryCount < Self.maxFlushRetryCount else {
            workplaceStoreLog.error("event=flush_retry_abandoned attempts=\(self.flushRetryCount, privacy: .public)")
            return
        }
        flushRetryCount += 1
        let delaySeconds = flushRetryBaseSeconds * flushRetryCount
        debouncedSyncStatesWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
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

    /// 预生成 workplaces/sync-states 两份文档(不写盘),供跨 Store 的原子提交组合使用:调用方
    /// (RepositoryStore.removeRepository、SettingsStore.updateRootPath)合并后一次落盘,失败整体回滚。
    func persistenceDocuments(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) throws -> [JSONFileStoreDocument] {
        try [
            fileStore.document(for: newWorkplaces, as: "workplaces.json"),
            fileStore.document(for: newSyncStates, as: "sync-states.json"),
        ]
    }

    /// 文档已由调用方原子提交成功后应用到内存,并取消待执行的防抖写盘(否则旧快照稍后会覆盖新状态)。
    func applyPersistedState(
        workplaces newWorkplaces: [Workplace],
        syncStates newSyncStates: [RepositorySyncState]
    ) {
        debouncedSyncStatesWriteTask?.cancel()
        debouncedSyncStatesWriteTask = nil
        workplaces = newWorkplaces
        syncStates = newSyncStates
        flushRetryCount = 0
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

    func createWorkplace(
        name: String,
        rootPath: String,
        selectedRepositories: [RepositoryConfig],
        branch: String? = nil
    ) throws -> Workplace
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


    /// 启动期对账:为"工作区已选中但 sync state 丢失"的仓库补建 idle 状态(如 sync-states.json 曾损坏被
    /// 重置),避免工作区永久不可用;仓库配置缺失或名称非法时跳过该仓库,留待用户编辑时生成。
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
                // 跳过必须留痕(对齐 updateSyncState 的策略):启动对账静默吞掉配置缺失/名称非法的仓库,
                // "选中但无状态行"在现场就无从排查。
                guard let repository = reposByID[repositoryID] else {
                    workplaceStoreLog.error(
                        "event=sync_state_backfill_skipped reason=repository_config_missing workplace_id=\(workplace.id, privacy: .public) repository_id=\(repositoryID, privacy: .public)"
                    )
                    continue
                }
                guard let localPath = try? Self.repositoryPath(
                    workplacePath: workplace.path,
                    repositoryName: repository.repoName
                ) else {
                    workplaceStoreLog.error(
                        "event=sync_state_backfill_skipped reason=invalid_repository_name workplace_id=\(workplace.id, privacy: .public) repository_id=\(repositoryID, privacy: .public)"
                    )
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

    /// 启动期对账:清理孤儿引用(跨 Store 两阶段持久化的中间失败窗口会留下"仓库已删、工作区仍引用它"),
    /// 同时清理 workplaceID 已不在集合内的 sync state——这类记录没有 UI 入口,不清理会在文件里永久累积。
    func pruneReferencesToRepositories(validRepositoryIDs: Set<UUID>) throws {
        // 有效集合为空但内存仍引用着仓库 ⇒ 上游数据异常(损坏/加载失败),不是"用户删光了仓库":
        // 此时直接放弃,避免把健康的工作区关联数据一并清空。
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
        // **字段所有权**:编辑流程只拥有 name/path/selectedRepositoryIDs/branch,其余取 Store 当前值。
        // 改名+克隆要等数分钟,期间用户的置顶/归档若被整条覆盖回入口快照,会被静默抹掉且无痕迹可查。
        let current = workplaces[index]
        var sanitizedWorkplace = workplace
        sanitizedWorkplace.isPinned = current.isPinned
        sanitizedWorkplace.isArchived = current.isArchived
        sanitizedWorkplace.pinnedRepositoryIDs = current.pinnedRepositoryIDs
        sanitizedWorkplace.createdAt = current.createdAt
        // 置顶清单按本轮最终勾选收敛:编辑可能摘除了某个仓库,指向它的 id 要跟着摘掉。
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
            // 未知 key 不能静默跳过:该行若在 await 期间被去重/prune 掉,跳过会让克隆结果不落库、UI 永远
            // 没有状态行。只补录仍属当前选中仓库的行,避免把已移出工作区的仓库状态"复活"。
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

    /// 清理"失败但本地目录仍在"的展示态(实际状态已在外部修复,如在命令行处理完冲突)。存在性探测可能落在
    /// 网盘/外置盘上、单次 `fileExists` 就能阻塞数分钟,故移出主线程;签名保持同步(调用方回调是同步闭包)。
    func clearFailedStatusesWhereDirectoryExists(workplaceID: UUID) {
        let candidates = syncStates.filter { state in
            state.workplaceID == workplaceID && state.status == .failed
        }
        guard candidates.isEmpty == false else { return }
        let candidateIDs = candidates.map(\.id)
        let paths = candidates.map(\.localPath)
        // 指纹:探测 Task 挂起期间同一行可能又产生新的 .failed,过期结果只配清掉"探测时刻"那份失败;
        // 落库前按 id 比对指纹(元组不 conform Equatable,故用拼接串),不一致的行跳过、避免误打成 .success。
        let fingerprintsByID = Dictionary<String, String>(
            candidates.map { state in
                (state.id, "\(state.lastError ?? "|")\(state.lastSyncedAt.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "nil")")
            },
            uniquingKeysWith: { _, new in new }
        )
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
                        // 缺键(探测后新增的行)与指纹不一致同样跳过清理。
                        && fingerprintsByID[state.id]
                            == "\(state.lastError ?? "|")\(state.lastSyncedAt.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "nil")"
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

    /// 计算"删除某仓库全部工作区关联"后的目标状态(不写盘),无变化返回 nil;供 RepositoryStore
    /// removeRepository 把 repositories.json 与工作区文档合并成一次原子提交,消除两阶段写的中间失败窗口。
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
        // 对齐 removeRepository:不存在的 id 不触发两文件全量落盘,也不把"删除成功"的假象传给调用方。
        // 文案用 workplaceAlreadyRemoved:走到这里时目录通常已删除成功,记录被并发移除即目标已达成。
        guard workplaces.contains(where: { $0.id == workplaceID }) else {
            throw WorkplaceStoreError.workplaceAlreadyRemoved
        }
        let updatedWorkplaces = workplaces.filter { $0.id != workplaceID }
        let updatedSyncStates = syncStates.filter { $0.workplaceID != workplaceID }
        try persist(workplaces: updatedWorkplaces, syncStates: updatedSyncStates)
    }

    /// 计算换根后的目标状态与迁移条数(不写盘),无需迁移返回 nil;供 SettingsStore.updateRootPath 与
    /// settings.json 一次原子提交——分开写盘失败会留下"记录指新根、设置仍是旧根",磁盘刷新据此永久删除。
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
        // 同步态跟随所属工作区迁移(旧路径→新路径),而不是各自对旧根求相对路径:
        // 否则嵌套根时已在新根下的工作区,其同步态会被二次嵌套。
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
        // isWithinDirectory 解析 symlink 且大小写不敏感,可能"解析后"同前缀而原始串不同,故词法截取前必须
        // 确认原始串以 root/ 开头;不能用 lowercased().hasPrefix + dropFirst——个别 Unicode(如 U+0130)
        guard let prefixRange = normalizedPath.range(
            of: root + "/",
            options: [.caseInsensitive]
        ), prefixRange.lowerBound == normalizedPath.startIndex else { return nil }
        return String(normalizedPath[prefixRange.upperBound...])
    }

    /// 仅测试直接调用的落库入口:本方法只写 workplaces/sync-states 两份文档,单独使用会在两次写之间留出
    /// 被并发整体覆写的窗口;生产路径一律走 `RepositoryStore.commitDiskRefresh`(三份文档单批原子提交)。
    func applyDiskRefreshResult(_ result: WorkplaceDiskRefreshResult) {
        guard result.changed else { return }
        do {
            try persist(
                workplaces: result.workplaces,
                syncStates: result.syncStates
            )
        } catch {
            workplaceStoreLog.error("event=disk_refresh_save_failed reason=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 用磁盘事实校正展示态(纯函数)。lockedPathKeys 是 `RepositoryOperationLock.inFlightPathKeys()` 快照:
    /// 命中的路径**不做破坏性改写**——长操作期间"记录存在、目录暂缺"是正常中间态,按陈旧磁盘视图删记录不可逆。
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

        var refreshedWorkplaces = workplaces
        var refreshedSyncStates = syncStates
        var changed = false

        // 摘除目录已不存在的记录(持锁/瞬态进行中的长操作豁免:见函数注释)。全缺普查必须在剔除在飞豁免
        // 之前:先剔再比总数的话,只要恰好有 1 个工作区在飞,根目录整体不可达时 allMissing 判定就失效。
        let fm = FileManager.default
        // 删除候选与"全缺"兜底的分母都先按 rootPath 收敛:根外记录一旦进分母,只要根外还有任何一条在盘上,
        // `候选数 == 总数` 就不成立、兜底整体失效,一次刷新会把根下全部旧记录连 sync states 永久删除。
        let workplacesUnderRoot = refreshedWorkplaces.filter { workplace in
            LocalPathSafety.isWithinDirectory(workplace.path, rootPath: trimmedRoot)
        }
        // 逐记录 fileExists 探测,而不是枚举根目录一层:contentsOfDirectory 只到下一级,换根 rebase 产生的
        // 嵌套工作区恒不在枚举集合里,会被"磁盘上明明还在"却当成用户删除而连记录带 sync states 一起清掉。
        let deletableCandidates = workplacesUnderRoot.filter { workplace in
            fm.fileExists(atPath: workplace.path) == false
        }
        let deletableMissing = deletableCandidates.filter { workplace in
            Self.isWorkplaceOperationInFlight(
                workplace,
                syncStates: refreshedSyncStates,
                lockedPathKeys: lockedPathKeys
            ) == false
        }
        // 根目录下的工作区同时全部缺失 ⇒ 更像换根/卷不可用,而不是用户删光了 N 个:
        // 跳过清理,一次刷新就不可能清空整个仓库库。
        let allMissing = !workplacesUnderRoot.isEmpty
            && deletableCandidates.count == workplacesUnderRoot.count
        let removedIDs = allMissing ? Set<UUID>() : Set(deletableMissing.map(\.id))
        if !removedIDs.isEmpty {
            refreshedWorkplaces.removeAll { removedIDs.contains($0.id) }
            refreshedSyncStates.removeAll { removedIDs.contains($0.workplaceID) }
            changed = true
        }

        for i in refreshedWorkplaces.indices {
            let workplace = refreshedWorkplaces[i]
            // 按目录名去重 sync states:keeper 优先取组内"被选中"的那行(否则取第一行)。留哪行若全由数组顺序
            // 决定,后出现的恰是用户刚选中的新配置时新行会被删、陈旧行反而留下;只移除非 keeper 行。
            var indicesByFolderName: [String: [Int]] = [:]
            for (idx, state) in refreshedSyncStates.enumerated() where state.workplaceID == workplace.id {
                let name = URL(fileURLWithPath: state.localPath).lastPathComponent
                indicesByFolderName[name, default: []].append(idx)
            }
            var duplicateIndices: [Int] = []
            for group in indicesByFolderName.values where group.count > 1 {
                let selectedIDs = Set(refreshedWorkplaces[i].selectedRepositoryIDs)
                let keeper = group.first { selectedIDs.contains(refreshedSyncStates[$0].repositoryID) } ?? group[0]
                for idx in group where idx != keeper {
                    duplicateIndices.append(idx)
                    let removedRepositoryID = refreshedSyncStates[idx].repositoryID
                    refreshedWorkplaces[i].selectedRepositoryIDs.removeAll { $0 == removedRepositoryID }
                    refreshedWorkplaces[i].pinnedRepositoryIDs = Self.sanitizedPinnedIDs(
                        refreshedWorkplaces[i].pinnedRepositoryIDs,
                        against: refreshedWorkplaces[i].selectedRepositoryIDs
                    )
                    changed = true
                }
            }
            // duplicateIndices 来自 Dictionary 分组遍历,不保证升序;必须先按索引降序
            // 再删除,否则删小索引会让后续索引整体前移(删错行,甚至越界 crash)。
            for idx in duplicateIndices.sorted(by: >) {
                refreshedSyncStates.remove(at: idx)
            }

            // 磁盘上缺失的仓库仍留在工作区里,UI 才能给出重试入口。
            for stateIndex in refreshedSyncStates.indices where
                refreshedSyncStates[stateIndex].workplaceID == workplace.id
            {
                let exists = fm.fileExists(atPath: refreshedSyncStates[stateIndex].localPath)
                if !exists {
                    // 瞬态(.cloning/.pulling/.switching/.removing)只由本进程活跃操作写入:此刻目录"缺失"多半是
                    // 操作还没落位(或正在整树移动),按陈旧磁盘视图改写会把进行中的行打成"本地仓库缺失"的假失败。
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


    nonisolated static func snapshot(
        workplaces: [Workplace],
        syncStates: [RepositorySyncState]
    ) -> WorkplaceStoreSnapshot {
        WorkplaceStoreSnapshot(
            workplaces: workplaces,
            syncStates: syncStates
        )
    }

    /// 瞬态只由本进程活跃操作写入(重启解码已归位 .idle),因此可以安全当作"进行中"信号。
    /// internal:SyncCoordinator 的 pull 预标要用同一判据,两处各写一份 switch 会随新状态加入而漂移。
    nonisolated static func isTransientSyncStatus(_ status: SyncStatus) -> Bool {
        switch status {
        case .cloning, .pulling, .switching, .removing:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    /// 工作区级豁免:目录本身持锁,或其任一仓库路径持锁/处于瞬态,本次刷新就不得因"目录暂缺"删除该记录。
    /// 锁快照为空**不能**否定豁免:长操作在两次持锁段之间存在无锁 await 窗口,瞬态行是唯一可靠进行中标记。
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
