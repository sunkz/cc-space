import Foundation
import os

private let repositoryStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RepositoryStore"
)

struct RepositoryBackupEntry: Codable, Equatable, Sendable {
    let gitURL: String
    var defaultBranch: String?
    var mrTargetBranches: [String] = []

    private enum CodingKeys: String, CodingKey {
        case gitURL
        case defaultBranch
        case mrTargetBranches
    }

    init(
        gitURL: String,
        defaultBranch: String? = nil,
        mrTargetBranches: [String] = []
    ) {
        self.gitURL = gitURL
        self.defaultBranch = defaultBranch
        self.mrTargetBranches = mrTargetBranches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitURL = try container.decode(String.self, forKey: .gitURL)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        mrTargetBranches = try container.decodeIfPresent([String].self, forKey: .mrTargetBranches) ?? []
    }
}

struct RepositoryBackupDocument: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let exportedAt: Date
    let repositories: [RepositoryBackupEntry]

    init(
        version: Int = currentVersion,
        exportedAt: Date = .now,
        repositories: [RepositoryBackupEntry]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.repositories = repositories
    }
}

struct RepositoryImportResult: Equatable, Sendable {
    let importedCount: Int
    let skippedCount: Int
    let mergedCount: Int
}

struct RepositoryDeduplicationResult: Sendable {
    let repositories: [RepositoryConfig]
    let changed: Bool
    /// 被删重复项 id → 保留项 id:把 selected/pinned/syncState 从被删项转到保留项,
    /// 直接摘除引用会让同时引用两条重复项的工作区明明有同 URL 的存活配置却丢掉仓库。
    var idRemapping: [UUID: UUID] = [:]
}

enum RepositoryStoreError: LocalizedError, Equatable {
    case duplicateURL
    case duplicateRepoName
    case invalidRepoName
    case notFound
    case invalidBackupFormat
    case unsupportedBackupVersion(Int)
    case emptyBackup
    case crossStoreRootMismatch

    var errorDescription: String? {
        switch self {
        case .duplicateURL:
            return "仓库地址已存在"
        case .duplicateRepoName:
            return "仓库名称已存在"
        case .invalidRepoName:
            return "仓库名称不能包含路径分隔符，且不能为 . 或 .."
        case .notFound:
            return "仓库不存在"
        case .invalidBackupFormat:
            return "备份文件格式无效"
        case .unsupportedBackupVersion(let version):
            return "暂不支持该备份文件版本：\(version)"
        case .emptyBackup:
            return "备份文件中没有仓库"
        case .crossStoreRootMismatch:
            return "内部状态异常：仓库与工作区的数据目录不一致，已取消本次操作"
        }
    }
}

private struct RepositoryBackupDocumentV1: Codable {
    let version: Int
    let exportedAt: Date
    let repositories: [String]
}

@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [RepositoryConfig]
    private let fileStore: JSONFileStore

    /// 本次启动 repositories.json 是否损坏并被重置为空;下游启动对账据此跳过破坏性清理,
    /// 避免单点损坏级联清空工作区数据。
    private(set) var didRecoverFromCorruptFile = false
    /// 最近一次启动期自动去重清理的条数(nil = 尚未发生过)。去重是不可撤销的硬删除,只写
    /// os_log 用户看不到"仓库少了一个"的原因,根视图据此给可见提示(事件由下面的序号触发)。
    @Published private(set) var lastDeduplicationCleanupCount: Int? = nil
    /// 去重事件序号:每次成功去重 +1。根视图按序号而非条数观察——`.onChange` 只在值变化时
    /// 回调,同启动期两次清理条数相同(2→2)时按条数观察会漏掉第二次。
    @Published private(set) var deduplicationCleanupSequence: Int = 0

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        // 抢救子集的回写必须排在 preserveCorruptFile **之后**(口径同 WorkplaceStore):save 走 rename
        // 原子覆写,先回写就把磁盘上的损坏字节销毁,随后 preserveCorruptFile 会把刚写好的子集改名拿走。
        var salvagedSubsetNeedsRewrite = false
        do {
            self.repositories = RepositoryStore.deduplicatedIDs(
                try fileStore.loadIfPresent([RepositoryConfig].self, from: "repositories.json", default: [])
            )
        } catch {
            repositoryStoreLog.error("event=load_repositories_failed reason=\(error.localizedDescription, privacy: .public)")
            didRecoverFromCorruptFile = true
            // 先逐元素容错抢救再保全原文件:preserveCorruptFile 会改名/复制原文件,放到后面就读不到原始内容。
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                RepositoryConfig.self,
                from: "repositories.json"
            ) {
                self.repositories = RepositoryStore.deduplicatedIDs(tolerated.values)
                repositoryStoreLog.error("event=recovered_partial_repositories kept=\(tolerated.values.count, privacy: .public) dropped=\(tolerated.droppedCount, privacy: .public)")
                salvagedSubsetNeedsRewrite = true
            } else {
                self.repositories = []
            }
            fileStore.preserveCorruptFile(named: "repositories.json")
        }
        if salvagedSubsetNeedsRewrite {
            do {
                try fileStore.save(self.repositories, as: "repositories.json")
            } catch {
                repositoryStoreLog.error(
                    "event=salvaged_subset_rewrite_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// 按 `id` 去重保留首条:手工编辑或容错抢救可能引入重复 id。不去重则 `deduplicationResult` 的
    /// keptIDs 会把两条同 id 记录都判为保留,UI ForEach(id: \.self) 撞重复身份,更新/删除只可达首条。
    nonisolated static func deduplicatedIDs(_ repositories: [RepositoryConfig]) -> [RepositoryConfig] {
        var seenIDs = Set<UUID>()
        return repositories.filter { seenIDs.insert($0.id).inserted }
    }

    /// 内存先行、同步写盘:写盘成功才改内存,失败抛给调用方回滚。刻意保持同步语义——跨文件原子提交
    /// 与失败回滚都依赖"写盘与状态更新在同一主线程顺序发生",改到后台队列会牵动失败回滚时序。
    private func persistRepositories(_ newRepositories: [RepositoryConfig]) throws {
        try fileStore.save(newRepositories, as: "repositories.json")
        repositories = newRepositories
    }

    private func validatedRepositoryName(from gitURL: String) throws -> String {
        let repoName = try GitURLParser.repositoryName(from: gitURL)
        do {
            return try LocalPathSafety.validateComponent(
                repoName,
                fieldName: "仓库名称"
            )
        } catch LocalPathSafetyError.invalidComponent {
            throw RepositoryStoreError.invalidRepoName
        }
    }

    private func makeBackupEncoder() -> JSONEncoder {
        JSONFileStore.makeEncoder()
    }

    /// nonisolated:备份解码可能被挪到后台线程调用(见 decodeBackupEntries),不能挂在 @MainActor 实例上。
    nonisolated private static func makeBackupDecoder() -> JSONDecoder {
        JSONFileStore.makeDecoder()
    }

    /// 建档一次落盘:此前"建档→回填 MR 目标分支"两步写,第二步失败会留下"UI 报新增失败、记录已存在、
    /// 重试撞 duplicateURL"的死角。返回实时记录供编排方直接使用,不必再按地址回查。
    @discardableResult
    func addRepository(gitURL: String) throws -> RepositoryConfig {
        let normalizedGitURL = Self.expandingHomeDirectory(
            gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard repositories.contains(where: { Self.gitURLsMatch($0.gitURL, normalizedGitURL) }) == false else {
            throw RepositoryStoreError.duplicateURL
        }

        let repoName = try validatedRepositoryName(from: normalizedGitURL)
        guard repositories.contains(where: { $0.repoName == repoName }) == false else {
            throw RepositoryStoreError.duplicateRepoName
        }

        let now = Date()
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: normalizedGitURL,
            repoName: repoName,
            createdAt: now,
            updatedAt: now
        )

        var updatedRepositories = repositories
        updatedRepositories.append(repository)
        try persistRepositories(updatedRepositories)
        return repository
    }

    /// internal:磁盘发现导入(`commitImportedRepositories`)要用同一套 URL 归一化口径判断远端是否已在池里,
    /// 另写一份必然与这里的规则漂移。
    nonisolated static func gitURLsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedGitURLForComparison(lhs) == normalizedGitURLForComparison(rhs)
    }

    /// 本地路径的 `~/` 在建档时展开成绝对路径:git 子进程不经过 shell,`~` 不会被展开,
    /// 原样入库后 ls-remote/clone 必然失败。只认整串以 `~` 开头;`git@host:~/x` 里的 `~` 属远端 shell 语义。
    nonisolated static func expandingHomeDirectory(_ gitURL: String) -> String {
        guard gitURL == "~" || gitURL.hasPrefix("~/") else { return gitURL }
        let home = NSHomeDirectory()
        return gitURL == "~" ? home : home + gitURL.dropFirst(1)
    }

    nonisolated private static func normalizedGitURLForComparison(_ url: String) -> String {
        var normalized = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // 循环"先剥尾部 / 再剥 .git"直到稳定(与 GitURLParser.normalizedRepositoryPath 顺序对齐):
        // 单次剥离会把 "https://x/repo.git/" 归一成 "https://x/repo/",与 "https://x/repo" 不相等。
        while true {
            let before = normalized
            if normalized.hasSuffix("/") {
                normalized = String(normalized.dropLast())
            }
            if normalized.hasSuffix(".git") {
                normalized = String(normalized.dropLast(4))
            }
            if normalized == before { break }
        }
        return normalized
    }

    /// 删仓库并同步清理所有工作区关联:repositories.json 与工作区文档(workplaces/sync-states)经一次
    /// `fileStore.save(documents)` 原子提交,任一失败整体回滚,不留"仓库已删、关联清理失败"的中间态。
    func removeRepository(id: UUID, workplaceStore: WorkplaceStore) throws {
        // 跨 Store 原子提交的前提是共用同一数据目录:注入分叉时 applyPersistedState 只更新内存、
        // 对方目录文件还是旧的,内存与盘静默背离,故提交前拦截。
        guard repositoryStoreRootsMatch(workplaceStore) else {
            throw RepositoryStoreError.crossStoreRootMismatch
        }
        // id 不存在要当场拦:否则不存在的 id 照常触发全量落盘(mtime/写放大照付),
        // 并把"删除成功"的假象传给调用方。
        guard repositories.contains(where: { $0.id == id }) else {
            throw RepositoryStoreError.notFound
        }
        let updatedRepositories = repositories.filter { $0.id != id }
        let associationState = workplaceStore.stateAfterRemovingRepositoryAssociations(repositoryID: id)

        var documents = [try fileStore.document(for: updatedRepositories, as: "repositories.json")]
        if let associationState {
            documents += try workplaceStore.persistenceDocuments(
                workplaces: associationState.workplaces,
                syncStates: associationState.syncStates
            )
        }
        try fileStore.save(documents)

        repositories = updatedRepositories
        if let associationState {
            workplaceStore.applyPersistedState(
                workplaces: associationState.workplaces,
                syncStates: associationState.syncStates
            )
        }
    }

    /// 仅测试直接调用的落库入口;生产路径一律走 `commitDiskRefresh`(它与 workplaces/sync-states 单批
    /// 原子提交,消灭"两步写之间被并发整体覆写"的窗口)。新增调用点前先确认是否需要跨文件原子性。
    func applyDeduplicationResult(_ result: RepositoryDeduplicationResult) {
        guard result.changed else { return }
        // 自动去重是不可撤销的硬删除:成功路径也要留痕,否则用户只会"发现仓库少了一个"而无从得知原因。
        let removedNames = Self.removedRepositoryNames(from: repositories, keeping: result.repositories)
        do {
            try persistRepositories(result.repositories)
            announceDeduplicationCleanup(removedNames)
        } catch {
            repositoryStoreLog.error("event=deduplication_save_failed reason=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removedRepositoryNames(
        from current: [RepositoryConfig],
        keeping kept: [RepositoryConfig]
    ) -> [String] {
        let keptIDs = Set(kept.map(\.id))
        return current.filter { keptIDs.contains($0.id) == false }.map(\.repoName)
    }

    nonisolated static func deduplicationResult(
        for repositories: [RepositoryConfig],
        protectedRepositoryIDs: Set<UUID> = []
    ) -> RepositoryDeduplicationResult {
        // 保留优先级:被工作区/同步态引用者 > createdAt 更早者 > 其余。按数组顺序"留第一条、硬删其余"
        // 可能删掉正被工作区引用的那条而留下新添加的重复记录(工作区静默丢仓库)。输出仍按原数组顺序。
        let prioritySorted = repositories.sorted { lhs, rhs in
            let lhsProtected = protectedRepositoryIDs.contains(lhs.id)
            let rhsProtected = protectedRepositoryIDs.contains(rhs.id)
            if lhsProtected != rhsProtected { return lhsProtected }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            // createdAt 只有 ISO8601 秒级精度,同秒创建时上面是平局;再比 repoName/id,避免"留哪条"不确定。
            if lhs.repoName != rhs.repoName { return lhs.repoName < rhs.repoName }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // 同 URL(归一化相等)= 同一远端被登记两次:字段并入保留项,引用记入 idRemapping 换挂过去。
        // 同名不同 URL 是不同远端:只留优先级高的一条,不得进 idRemapping(否则工作区静默 pull/push 未配置的远端)。
        var keptRepositories: [RepositoryConfig] = []
        var keptIndexByURL: [String: Int] = [:]
        var keptIndexByName: [String: Int] = [:]
        var idRemapping: [UUID: UUID] = [:]
        // "同名不同 URL"被丢弃项的 id 按归一化 URL 暂存:后面若出现**同 URL** 的存活配置,
        // 引用就该挂到它身上(仍是同一远端),而不是被兜底摘除。
        var pendingSameURLRemaps: [String: [UUID]] = [:]

        for repository in prioritySorted {
            let normalizedURL = normalizedGitURLForComparison(repository.gitURL)
            if let index = keptIndexByURL[normalizedURL] {
                let merged = mergingDuplicate(kept: keptRepositories[index], dropped: repository)
                keptRepositories[index] = merged
                idRemapping[repository.id] = merged.id
                continue
            }
            if let index = keptIndexByName[repository.repoName] {
                pendingSameURLRemaps[normalizedURL, default: []].append(repository.id)
                repositoryStoreLog.error(
                    "event=dedup_rejected_cross_url_name_conflict repo_name=\(repository.repoName, privacy: .public) dropped_url=\(repository.gitURL, privacy: .public) kept_url=\(keptRepositories[index].gitURL, privacy: .public) reason=同名不同远端,重映射会把工作区指向未配置过的远端,改为摘除引用"
                )
                continue
            }
            // 存活项的 URL 命中此前丢弃项:那些被丢弃的引用改挂到本条(同远端,安全)。
            if let pendingIDs = pendingSameURLRemaps.removeValue(forKey: normalizedURL) {
                for droppedID in pendingIDs {
                    idRemapping[droppedID] = repository.id
                }
            }
            keptIndexByURL[normalizedURL] = keptRepositories.count
            keptIndexByName[repository.repoName] = keptRepositories.count
            keptRepositories.append(repository)
        }

        let mergedByID = Dictionary(
            keptRepositories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deduplicatedRepositories = repositories.compactMap { mergedByID[$0.id] }
        return RepositoryDeduplicationResult(
            repositories: deduplicatedRepositories,
            changed: deduplicatedRepositories.count != repositories.count,
            idRemapping: idRemapping
        )
    }

    /// 重复项字段并入保留项:defaultBranch 缺省才回填;mrTargetBranches 保序并集。
    nonisolated private static func mergingDuplicate(kept: RepositoryConfig, dropped: RepositoryConfig) -> RepositoryConfig {
        var merged = kept
        if merged.defaultBranch == nil {
            merged.defaultBranch = dropped.defaultBranch
        }
        let existingBranches = Set(kept.mrTargetBranches)
        let appended = kept.mrTargetBranches + dropped.mrTargetBranches.filter { !existingBranches.contains($0) }
        merged.mrTargetBranches = RepositoryConfig.deduplicated(appended)
        return merged
    }

    /// 引用重映射(取代摘除):selected/pinned 中被删项的 id 换成保留项 id,
    /// 换完去重保序(同一工作区同时引用两条重复项时收敛为一条)。
    nonisolated static func remappingReferences(
        from workplaces: [Workplace],
        idRemapping: [UUID: UUID]
    ) -> [Workplace] {
        guard idRemapping.isEmpty == false else { return workplaces }
        return workplaces.map { workplace in
            var updated = workplace
            updated.selectedRepositoryIDs = remapUnique(workplace.selectedRepositoryIDs, idRemapping)
            updated.pinnedRepositoryIDs = remapUnique(workplace.pinnedRepositoryIDs, idRemapping)
            return updated
        }
    }

    nonisolated private static func remapUnique(_ ids: [UUID], _ remapping: [UUID: UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.compactMap { id in
            let mapped = remapping[id] ?? id
            return seen.insert(mapped).inserted ? mapped : nil
        }
    }

    /// sync-states 重映射:存活项行优先保留,被删项行改挂保留项 id 后按 (workplaceID, repositoryID) 去重。
    /// 撞组合键时优先保留 `hasLocalDirectory == true` 的行:留 false 会误报"本地目录缺失"并诱发多余的重新克隆。
    nonisolated static func remappingSyncStates(
        _ syncStates: [RepositorySyncState],
        idRemapping: [UUID: UUID]
    ) -> [RepositorySyncState] {
        guard idRemapping.isEmpty == false else { return syncStates }
        let keptRows = syncStates.filter { idRemapping[$0.repositoryID] == nil }
        var result = keptRows
        var keptIndexByKey: [String: Int] = [:]
        for (index, row) in keptRows.enumerated() {
            // 组合键理论上唯一;真出现双行时维持既有的"留第一条"口径。
            keptIndexByKey["\(row.workplaceID.uuidString)-\(row.repositoryID.uuidString)"] = index
        }
        for state in syncStates {
            guard let newRepositoryID = idRemapping[state.repositoryID] else { continue }
            let key = "\(state.workplaceID.uuidString)-\(newRepositoryID.uuidString)"
            let remapped = RepositorySyncState(
                workplaceID: state.workplaceID,
                repositoryID: newRepositoryID,
                status: state.status,
                localPath: state.localPath,
                lastError: state.lastError,
                lastSyncedAt: state.lastSyncedAt,
                hasLocalDirectory: state.hasLocalDirectory
            )
            guard let existingIndex = keptIndexByKey[key] else {
                keptIndexByKey[key] = result.count
                result.append(remapped)
                continue
            }
            guard state.hasLocalDirectory, result[existingIndex].hasLocalDirectory == false else {
                continue
            }
            result[existingIndex] = remapped
        }
        return result
    }

    nonisolated static func removingReferences(
        from workplaces: [Workplace],
        to removedRepositoryIDs: Set<UUID>
    ) -> [Workplace] {
        guard removedRepositoryIDs.isEmpty == false else { return workplaces }
        return workplaces.map { workplace in
            var updated = workplace
            updated.selectedRepositoryIDs.removeAll { removedRepositoryIDs.contains($0) }
            updated.pinnedRepositoryIDs.removeAll { removedRepositoryIDs.contains($0) }
            return updated
        }
    }

    /// 磁盘刷新结果 + 去重硬删除的**单批原子提交**:三份文档一次 `save(documents)`,任一失败整体回滚。
    /// 两步写(先 apply 刷新结果、再单独 prune)之间任何并发跨 Store 提交都会用旧内存把首步整体覆写回盘。
    func commitDiskRefresh(
        workplaceResult: WorkplaceDiskRefreshResult,
        repositoryResult: RepositoryDeduplicationResult,
        workplaceStore: WorkplaceStore
    ) throws {
        guard repositoryStoreRootsMatch(workplaceStore) else {
            throw RepositoryStoreError.crossStoreRootMismatch
        }
        // 引用处理:先按 idRemapping 重映射到保留项,再对**未被映射覆盖**的被删 id 兜底摘除
        // (调用方手工构造结果或未来新增删除来源时不留悬空引用);改写基于快照输入。
        let keptIDs = Set(repositoryResult.repositories.map(\.id))
        let removedIDs = Set(repositories.map(\.id)).subtracting(keptIDs)
        let remappedWorkplaces = Self.removingReferences(
            from: Self.remappingReferences(
                from: workplaceResult.workplaces,
                idRemapping: repositoryResult.idRemapping
            ),
            to: removedIDs
        )
        let remappedSyncStates = Self.remappingSyncStates(
            workplaceResult.syncStates,
            idRemapping: repositoryResult.idRemapping
        ).filter { removedIDs.contains($0.repositoryID) == false }
        let applyWorkplaceChanges = workplaceResult.changed
            || remappedWorkplaces != workplaceResult.workplaces
            || remappedSyncStates != workplaceResult.syncStates

        var documents = [JSONFileStoreDocument]()
        if repositoryResult.changed {
            documents.append(try fileStore.document(for: repositoryResult.repositories, as: "repositories.json"))
        }
        if applyWorkplaceChanges {
            documents += try workplaceStore.persistenceDocuments(
                workplaces: remappedWorkplaces,
                syncStates: remappedSyncStates
            )
        }
        guard documents.isEmpty == false else { return }
        try fileStore.save(documents)

        if repositoryResult.changed {
            let removedNames = Self.removedRepositoryNames(from: repositories, keeping: repositoryResult.repositories)
            repositories = repositoryResult.repositories
            announceDeduplicationCleanup(removedNames)
        }
        if applyWorkplaceChanges {
            workplaceStore.applyPersistedState(
                workplaces: remappedWorkplaces,
                syncStates: remappedSyncStates
            )
        }
    }

    /// 提交磁盘发现导入:以**调用时刻**的三个 Store 内存状态重新生成计划,再一次原子落盘;导入只追加、不删。
    /// 重新生成是必须的:候选枚举 + 逐个读远端地址期间用户可能增删仓库或工作区,套用旧快照会把并发写入覆写回盘。
    func commitImportedRepositories(
        discovered: [DiscoveredGitRepository],
        workplaceStore: WorkplaceStore
    ) throws -> Int {
        guard discovered.isEmpty == false else { return 0 }
        guard repositoryStoreRootsMatch(workplaceStore) else {
            throw RepositoryStoreError.crossStoreRootMismatch
        }
        let result = ExternalRepositoryImport.importPlan(
            discovered: discovered,
            workplaces: workplaceStore.workplaces,
            syncStates: workplaceStore.syncStates,
            repositories: repositories
        )
        // 跳过必须留痕:用户视角是"拷进去的仓库怎么没出现",没有日志就无从回答原因。
        for skip in result.skips {
            repositoryStoreLog.notice(
                "event=external_repo_import_skipped reason=\(skip.reason.rawValue) path=\(skip.path)"
            )
        }
        guard result.changed else { return 0 }

        var documents = [try fileStore.document(for: result.repositories, as: "repositories.json")]
        documents += try workplaceStore.persistenceDocuments(
            workplaces: result.workplaces,
            syncStates: result.syncStates
        )
        try fileStore.save(documents)

        repositories = result.repositories
        workplaceStore.applyPersistedState(
            workplaces: result.workplaces,
            syncStates: result.syncStates
        )
        repositoryStoreLog.notice(
            "event=external_repo_imported count=\(result.importedCount, privacy: .public)"
        )
        return result.importedCount
    }

    private func announceDeduplicationCleanup(_ removedNames: [String]) {
        lastDeduplicationCleanupCount = removedNames.count
        deduplicationCleanupSequence += 1
        repositoryStoreLog.notice(
            "event=deduplication_removed count=\(removedNames.count) names=\(removedNames.joined(separator: ","), privacy: .private)"
        )
    }

    private func repositoryStoreRootsMatch(_ workplaceStore: WorkplaceStore) -> Bool {
        fileStore.rootDirectory.standardizedFileURL
            == workplaceStore.rootDirectoryForCrossStoreCheck.standardizedFileURL
    }

    /// 按 id 取实时记录:视图里多处要按 id 回查最新值(面板闭包捕获的行快照从第二次
    /// 点击起就是旧的),收成一个入口免得每处重抄谓词。
    func repository(for id: UUID) -> RepositoryConfig? {
        repositories.first { $0.id == id }
    }

    private func mutateRepository(id: UUID, _ mutate: (inout RepositoryConfig) -> Void) throws {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else {
            throw RepositoryStoreError.notFound
        }
        var updatedRepositories = repositories
        mutate(&updatedRepositories[index])
        updatedRepositories[index].updatedAt = .now
        try persistRepositories(updatedRepositories)
    }

    func updateMRTargetBranches(id: UUID, branches: [String]) throws {
        try mutateRepository(id: id) { $0.mrTargetBranches = branches }
    }

    func updateDefaultBranch(id: UUID, branch: String) throws {
        try mutateRepository(id: id) { $0.defaultBranch = branch }
    }

    func exportBackup(to fileURL: URL) throws -> RepositoryBackupDocument {
        let document = RepositoryBackupDocument(
            repositories: repositories.map {
                RepositoryBackupEntry(
                    gitURL: $0.gitURL,
                    defaultBranch: $0.defaultBranch,
                    mrTargetBranches: $0.mrTargetBranches
                )
            }
        )
        let encoder = makeBackupEncoder()
        let data = try encoder.encode(document)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        // 目标路径由用户自选(不受数据目录 0600 管辖),备份含完整仓库清单,写完补一次仅本人可读写。
        // 收紧失败不影响导出结果,但必须留痕:`try?` 静默会让"权限没收紧"这件事完全无从发现。
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // reason 要能从日志里读出:动态 String 插值默认 private,不标 .public 会被脱敏成 <private>。
            repositoryStoreLog.error(
                "event=backup_permission_hardening_failed reason=\(error.localizedDescription, privacy: .public)"
            )
        }
        return document
    }

    func importBackup(from fileURL: URL) throws -> RepositoryImportResult {
        try importBackup(entries: try Self.decodeBackupEntries(from: fileURL))
    }

    /// 读备份文件并解码(v2/v1 兼容 + 版本门槛 + 空条目清洗)。nonisolated:大备份"读盘 + JSON 解码"可达
    /// 秒级,调用方可把它挪出主 actor(见 OnboardingView),主线程只保留合并落盘的 importBackup(entries:)。
    nonisolated static func decodeBackupEntries(from fileURL: URL) throws -> [RepositoryBackupEntry] {
        let data = try Data(contentsOf: fileURL)
        let decoder = Self.makeBackupDecoder()

        let entries: [RepositoryBackupEntry]
        let version: Int

        if let v2Doc = try? decoder.decode(RepositoryBackupDocument.self, from: data) {
            entries = v2Doc.repositories
            version = v2Doc.version
        } else if let v1Doc = try? decoder.decode(RepositoryBackupDocumentV1.self, from: data) {
            entries = v1Doc.repositories.map { RepositoryBackupEntry(gitURL: $0) }
            version = v1Doc.version
        } else {
            throw RepositoryStoreError.invalidBackupFormat
        }

        // 版本必须落在受支持的区间:只设上界时,version 为 0/负数(手工编辑或伪造的备份)也会被当受支持版本导入。
        guard (1...RepositoryBackupDocument.currentVersion).contains(version) else {
            throw RepositoryStoreError.unsupportedBackupVersion(version)
        }

        let cleanedEntries = entries.filter {
            !$0.gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleanedEntries.isEmpty else {
            throw RepositoryStoreError.emptyBackup
        }
        return cleanedEntries
    }

    func importBackup(entries cleanedEntries: [RepositoryBackupEntry]) throws -> RepositoryImportResult {
        var existingNames = Set(repositories.map(\.repoName))
        var updatedRepositories = repositories
        // 归一化 URL → 下标:原写法每条 entry 都拿全池做一次 firstIndex 比较
        // (且每次比较各做两遍归一化),条目多时是 O(条目×池)。首见优先,与 firstIndex 同语义。
        var existingIndexByGitURL: [String: Int] = [:]
        for (index, repository) in updatedRepositories.enumerated() {
            let existingKey = Self.normalizedGitURLForComparison(repository.gitURL)
            if existingIndexByGitURL[existingKey] == nil {
                existingIndexByGitURL[existingKey] = index
            }
        }
        var importedCount = 0
        var skippedCount = 0
        var mergedCount = 0

        for (entryIndex, entry) in cleanedEntries.enumerated() {
            // 与 addRepository 同一口径展开 `~/`:备份文件可被手工编辑,一条
            // `~/remotes/x.git` 原样入库就是一个永远克隆不下来的死地址(git 不展波浪号)。
            let gitURL = Self.expandingHomeDirectory(
                entry.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // 单条非法 URL 不得让整个导入中止:备份文件可能来自不同版本/手工编辑,
            // 一条坏数据毁掉全部有效条目(含本可合并的更新)是最差结果。计入 skipped。
            guard let repoName = try? validatedRepositoryName(from: gitURL) else {
                repositoryStoreLog.error("event=import_entry_rejected index=\(entryIndex, privacy: .public)")
                skippedCount += 1
                continue
            }

            let matchKey = Self.normalizedGitURLForComparison(gitURL)
            if let existingIndex = existingIndexByGitURL[matchKey] {
                var changed = false
                if updatedRepositories[existingIndex].defaultBranch == nil, let entryDefault = entry.defaultBranch {
                    updatedRepositories[existingIndex].defaultBranch = entryDefault
                    changed = true
                }
                if !entry.mrTargetBranches.isEmpty {
                    // 必须过 `RepositoryConfig.deduplicated` 这一不变式收敛点:备份条目解码不去重,按"现有集合"
                    // 过滤只拦得下跨条目重复,条目自身的重复会原样并入 → 分支胶囊 ForEach(id: \.self) 撞重复身份。
                    let mergedBranches = RepositoryConfig.deduplicated(
                        updatedRepositories[existingIndex].mrTargetBranches + entry.mrTargetBranches
                    )
                    if mergedBranches != updatedRepositories[existingIndex].mrTargetBranches {
                        updatedRepositories[existingIndex].mrTargetBranches = mergedBranches
                        changed = true
                    }
                }
                if changed {
                    updatedRepositories[existingIndex].updatedAt = .now
                    mergedCount += 1
                } else {
                    skippedCount += 1
                }
                continue
            }

            if existingNames.contains(repoName) {
                skippedCount += 1
                continue
            }

            let now = Date()
            updatedRepositories.append(
                RepositoryConfig(
                    id: UUID(),
                    gitURL: gitURL,
                    repoName: repoName,
                    defaultBranch: entry.defaultBranch,
                    mrTargetBranches: entry.mrTargetBranches,
                    createdAt: now,
                    updatedAt: now
                )
            )
            existingNames.insert(repoName)
            existingIndexByGitURL[matchKey] = updatedRepositories.count - 1
            importedCount += 1
        }

        if importedCount > 0 || mergedCount > 0 {
            try persistRepositories(updatedRepositories)
        }

        return RepositoryImportResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            mergedCount: mergedCount
        )
    }
}
