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

    init(gitURL: String, defaultBranch: String? = nil, mrTargetBranches: [String] = []) {
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

    var hasChanges: Bool {
        importedCount > 0 || mergedCount > 0
    }
}

struct RepositoryDeduplicationResult: Sendable {
    let repositories: [RepositoryConfig]
    let changed: Bool
}

enum RepositoryStoreError: LocalizedError, Equatable {
    case duplicateURL
    case duplicateRepoName
    case invalidRepoName
    case notFound
    case repoNameChangeNotSupported
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
        case .repoNameChangeNotSupported:
            return "暂不支持通过编辑修改仓库名称，请新增仓库后替换"
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

    /// 本次启动 repositories.json 是否损坏并被重置为空。
    /// 下游启动对账需据此跳过破坏性清理,避免单点损坏级联清空工作区数据。
    private(set) var didRecoverFromCorruptFile = false
    /// 最近一次启动期自动去重实际清理的条数:nil 表示尚未发生过。
    /// 去重是不可撤销的硬删除,只写 os_log 用户看不到"仓库少了一个"的原因,
    /// 根视图据此给可见提示。本值只是提示里的条数**载荷**:事件由下面的单调
    /// 序号触发观察,入队合并后可多次展示(见 DeduplicationNoticeQueue),
    /// 不是"只提示一次"的开关。
    @Published private(set) var lastDeduplicationCleanupCount: Int? = nil
    /// 去重事件序号:每次成功去重 +1,单调递增。
    /// 根视图按序号观察事件而非条数——`.onChange` 只在值变化时回调,
    /// 同启动期两次清理条数相同(2→2)时按条数观察会漏掉第二次。
    @Published private(set) var deduplicationCleanupSequence: Int = 0

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        do {
            self.repositories = RepositoryStore.deduplicatedIDs(
                try fileStore.loadIfPresent([RepositoryConfig].self, from: "repositories.json", default: [])
            )
        } catch {
            repositoryStoreLog.error("event=load_repositories_failed reason=\(error.localizedDescription, privacy: .public)")
            didRecoverFromCorruptFile = true
            // 先逐元素容错抢救再保全原文件:preserveCorruptFile 会改名/复制原文件,
            // 放到后面就读不到原始内容了。单条坏记录不该让整个仓库列表报废。
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                RepositoryConfig.self,
                from: "repositories.json"
            ) {
                self.repositories = RepositoryStore.deduplicatedIDs(tolerated.values)
                repositoryStoreLog.error("event=recovered_partial_repositories kept=\(tolerated.values.count, privacy: .public) dropped=\(tolerated.droppedCount, privacy: .public)")
            } else {
                self.repositories = []
            }
            fileStore.preserveCorruptFile(named: "repositories.json")
        }
    }

    /// 按 `id` 去重保留首条:手工编辑或容错抢救可能引入重复 id。不去重则
    /// `deduplicationResult` 的 keptIDs(Set<UUID>)会把两条不同 URL/名称的同 id
    /// 记录都判为保留,UI ForEach(id: \.self) 撞重复身份,更新/删除只可达首条。
    nonisolated static func deduplicatedIDs(_ repositories: [RepositoryConfig]) -> [RepositoryConfig] {
        var seenIDs = Set<UUID>()
        return repositories.filter { seenIDs.insert($0.id).inserted }
    }

    /// 内存先行、同步写盘:写盘成功才改内存,失败抛给调用方回滚。
    /// 已知代价:每次写都是一次同步磁盘 I/O,数据目录在外置盘/网盘上时可能阻塞
    /// 主线程数秒。刻意保持同步语义——跨文件原子提交与失败回滚都依赖
    /// "写盘与状态更新在同一主线程上顺序发生",改成后台队列会牵动失败回滚时序。
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

    /// nonisolated:备份解码可能被挪到后台线程调用(见 decodeBackupEntries),
    /// 不能挂在 @MainActor 实例上。
    nonisolated private static func makeBackupDecoder() -> JSONDecoder {
        JSONFileStore.makeDecoder()
    }

    func addRepository(gitURL: String) throws {
        let normalizedGitURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)

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
    }

    /// internal:磁盘发现导入(`commitImportedRepositories`)要用同一套 URL 归一化口径
    /// 判断"这个远端是否已在仓库池里",另写一份必然与这里的规则漂移。
    nonisolated static func gitURLsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedGitURLForComparison(lhs) == normalizedGitURLForComparison(rhs)
    }

    nonisolated private static func normalizedGitURLForComparison(_ url: String) -> String {
        var normalized = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // 循环"先剥尾部 / 再剥 .git"直到稳定(与 GitURLParser.normalizedRepositoryPath
        // 的顺序对齐):单次剥离会把 "https://x/repo.git/" 归一成 "https://x/repo/"
        // (先剥 .git 不命中,再剥 / 后已无机会回头剥 .git),与 "https://x/repo" 不相等。
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

    /// 删除仓库并同步清理所有工作区对它的关联。
    /// `workplaceStore` 必须显式传入:删仓库天然要清工作区引用,省略会留下悬空引用。
    /// repositories.json 与工作区文档(workplaces/sync-states)通过一次
    /// `fileStore.save(documents)` 原子提交,任一失败整体回滚,不再存在
    /// "仓库已删、关联清理失败只记 warning"的中间态。
    /// 注意:要求两个 Store 共用同一数据目录(生产环境由 RootSplitView 注入同一 fileStore)。
    func removeRepository(id: UUID, workplaceStore: WorkplaceStore) throws {
        // 跨 Store 原子提交的前提是共用同一数据目录(注释级约定 → 运行时校验):
        // 注入分叉时 applyPersistedState 会把内存更新到新状态、对方目录文件还是旧的,
        // 内存与盘静默背离。宁可在提交前拦截。
        guard fileStore.rootDirectory.standardizedFileURL
            == workplaceStore.rootDirectoryForCrossStoreCheck.standardizedFileURL else {
            throw RepositoryStoreError.crossStoreRootMismatch
        }
        // 与 updateRepository 一致校验 id 存在:不存在的 id 此前会照常触发
        // 全量落盘(内容不变但 mtime/写放大照付),并把"删除成功"的假象传给调用方。
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

    func applyDeduplicationResult(_ result: RepositoryDeduplicationResult) {
        guard result.changed else { return }
        // 自动去重是**硬删除**且立刻写盘、不可撤销。此前只有失败才留痕,
        // 用户只会某次打开时"发现仓库少了一个"而无从得知原因,成功路径同样要记。
        let removedNames = Self.removedRepositoryNames(from: repositories, keeping: result.repositories)
        do {
            try persistRepositories(result.repositories)
            // 可见提示由根视图消费(仅 os_log 用户看不到"仓库少了一个"的原因)。
            lastDeduplicationCleanupCount = removedNames.count
            deduplicationCleanupSequence += 1
            repositoryStoreLog.notice(
                "event=deduplication_removed count=\(removedNames.count) names=\(removedNames.joined(separator: ","), privacy: .private)"
            )
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
    ) -> RepositoryDeduplicationResult {        // 保留优先级排序:被工作区/同步态引用者 > createdAt 更早者 > 其余。
        // 旧逻辑按数组顺序"保留第一条、硬删其余",可能删掉的恰是被工作区引用的
        // 那条而留下新添加的重复记录——工作区静默丢仓库。结果仍按原数组顺序输出,
        // 不改变列表展示序。
        let prioritySorted = repositories.sorted { lhs, rhs in
            let lhsProtected = protectedRepositoryIDs.contains(lhs.id)
            let rhsProtected = protectedRepositoryIDs.contains(rhs.id)
            if lhsProtected != rhsProtected { return lhsProtected }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            // createdAt 是 ISO8601 秒级精度,同秒创建时上面的比较是平局;
            // 再比 repoName/id 兜底,避免依赖非稳定排序导致"留哪条"不确定。
            if lhs.repoName != rhs.repoName { return lhs.repoName < rhs.repoName }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var existingNormalizedURLs = Set<String>()
        var existingNames = Set<String>()
        var keptIDs = Set<UUID>()

        for repository in prioritySorted {
            let normalizedURL = normalizedGitURLForComparison(repository.gitURL)
            if existingNormalizedURLs.contains(normalizedURL) || existingNames.contains(repository.repoName) {
                continue
            }
            existingNormalizedURLs.insert(normalizedURL)
            existingNames.insert(repository.repoName)
            keptIDs.insert(repository.id)
        }

        let deduplicatedRepositories = repositories.filter { keptIDs.contains($0.id) }
        return RepositoryDeduplicationResult(
            repositories: deduplicatedRepositories,
            changed: deduplicatedRepositories.count != repositories.count
        )
    }

    /// 从工作区记录中摘除对 `removedRepositoryIDs` 的选中/置顶引用(纯函数)。
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

    /// 磁盘刷新结果 + 去重硬删除的**单批原子提交**:三份文档(repositories/
    /// workplaces/sync-states)一次 `save(documents)` 落盘,任一失败整体回滚。
    /// 取代此前"apply 刷新结果 → 再单独 pruneReferencesToRepositories"的两步写:
    /// 两步之间任何并发跨 Store 提交(如 removeRepository)会基于旧内存把首步结果
    /// 整体覆写回盘,且立即 prune 落盘的又是新内存——去重删除与其引用清理
    /// 不再原子,悬空引用窗口重新打开。
    func commitDiskRefresh(
        workplaceResult: WorkplaceDiskRefreshResult,
        repositoryResult: RepositoryDeduplicationResult,
        workplaceStore: WorkplaceStore
    ) throws {
        guard repositoryStoreRootsMatch(workplaceStore) else {
            throw RepositoryStoreError.crossStoreRootMismatch
        }
        let keptIDs = Set(repositoryResult.repositories.map(\.id))
        let removedIDs = Set(repositories.map(\.id)).subtracting(keptIDs)
        // 引用摘除基于**快照输入**(workplaceResult.workplaces,即刷新计算所用状态),
        // 与 diskRefreshResult 自身的去重改写在同一份数据上完成,再单独 prune 一步省掉。
        let prunedWorkplaces = Self.removingReferences(
            from: workplaceResult.workplaces,
            to: removedIDs
        )
        let filteredSyncStates = workplaceResult.syncStates.filter {
            removedIDs.contains($0.repositoryID) == false
        }
        let applyWorkplaceChanges = workplaceResult.changed
            || prunedWorkplaces != workplaceResult.workplaces
            || filteredSyncStates.count != workplaceResult.syncStates.count

        var documents = [JSONFileStoreDocument]()
        if repositoryResult.changed {
            documents.append(try fileStore.document(for: repositoryResult.repositories, as: "repositories.json"))
        }
        if applyWorkplaceChanges {
            documents += try workplaceStore.persistenceDocuments(
                workplaces: prunedWorkplaces,
                syncStates: filteredSyncStates
            )
        }
        guard documents.isEmpty == false else { return }
        try fileStore.save(documents)

        if repositoryResult.changed {
            let removedNames = Self.removedRepositoryNames(from: repositories, keeping: repositoryResult.repositories)
            repositories = repositoryResult.repositories
            lastDeduplicationCleanupCount = removedNames.count
            deduplicationCleanupSequence += 1
            repositoryStoreLog.notice(
                "event=deduplication_removed count=\(removedNames.count) names=\(removedNames.joined(separator: ","), privacy: .private)"
            )
        }
        if applyWorkplaceChanges {
            workplaceStore.applyPersistedState(
                workplaces: prunedWorkplaces,
                syncStates: filteredSyncStates
            )
        }
    }

    /// 提交磁盘发现导入:以**调用时刻**的三个 Store 内存状态重新生成计划,
    /// 再把 repositories/workplaces/sync-states 一次原子落盘。
    ///
    /// 重新生成(而不是套用后台算好的结果)是必须的:候选枚举 + 逐个读远端地址
    /// 期间,用户可能增删仓库或工作区,套用旧快照会把并发的写入整体覆写回盘。
    /// 导入只做追加,复用同一 URL 的既有配置,不删任何东西。
    /// - Returns: 实际纳入列表的仓库数;0 表示本轮没有可导入的目录。
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

    private func repositoryStoreRootsMatch(_ workplaceStore: WorkplaceStore) -> Bool {
        fileStore.rootDirectory.standardizedFileURL
            == workplaceStore.rootDirectoryForCrossStoreCheck.standardizedFileURL
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

    func updateRepository(id: UUID, gitURL: String, mrTargetBranches: [String]? = nil) throws {
        let normalizedGitURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let index = repositories.firstIndex(where: { $0.id == id }) else {
            throw RepositoryStoreError.notFound
        }

        guard !repositories.contains(where: { $0.id != id && Self.gitURLsMatch($0.gitURL, normalizedGitURL) }) else {
            throw RepositoryStoreError.duplicateURL
        }

        let repoName = try validatedRepositoryName(from: normalizedGitURL)
        guard repoName == repositories[index].repoName else {
            throw RepositoryStoreError.repoNameChangeNotSupported
        }
        guard !repositories.contains(where: { $0.id != id && $0.repoName == repoName }) else {
            throw RepositoryStoreError.duplicateRepoName
        }

        var updatedRepositories = repositories
        updatedRepositories[index].gitURL = normalizedGitURL
        if let mrTargetBranches {
            updatedRepositories[index].mrTargetBranches = mrTargetBranches
        }
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
        // 目标路径由用户自选(不受数据目录 0600 收紧的管辖),备份含完整仓库清单,
        // 写完补一次仅本人可读写。收紧失败不影响导出结果(文件保持默认权限),
        // 但此前 `try?` 连日志都没有,失败完全无从发现——必须留痕。
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

    /// 读备份文件并解码(v2/v1 兼容 + 版本门槛 + 空条目清洗)。
    /// nonisolated:大备份"读盘 + JSON 解码"可达秒级,调用方可把它挪出主 actor
    /// (见 OnboardingView),主线程只保留合并落盘的 importBackup(entries:)。
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

        // 版本必须落在受支持的区间:此前只设上界,version 为 0/负数(手工编辑或
        // 伪造的备份)也会被当受支持版本导入。
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

    /// 把已解码的备份条目合并进当前列表并落盘。读写 @Published repositories,
    /// 只能在 MainActor 上调用。
    func importBackup(entries cleanedEntries: [RepositoryBackupEntry]) throws -> RepositoryImportResult {
        var existingNames = Set(repositories.map(\.repoName))
        var updatedRepositories = repositories
        var importedCount = 0
        var skippedCount = 0
        var mergedCount = 0

        for (entryIndex, entry) in cleanedEntries.enumerated() {
            let gitURL = entry.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
            // 单条非法 URL 不得让整个导入中止:备份文件可能来自不同版本/手工编辑,
            // 一条坏数据毁掉全部有效条目(含本可合并的更新)是最差结果。计入 skipped。
            guard let repoName = try? validatedRepositoryName(from: gitURL) else {
                repositoryStoreLog.error("event=import_entry_rejected index=\(entryIndex, privacy: .public)")
                skippedCount += 1
                continue
            }

            if let existingIndex = updatedRepositories.firstIndex(where: { Self.gitURLsMatch($0.gitURL, gitURL) }) {
                var changed = false
                if updatedRepositories[existingIndex].defaultBranch == nil, let entryDefault = entry.defaultBranch {
                    updatedRepositories[existingIndex].defaultBranch = entryDefault
                    changed = true
                }
                if !entry.mrTargetBranches.isEmpty {
                    let existing = Set(updatedRepositories[existingIndex].mrTargetBranches)
                    let newBranches = entry.mrTargetBranches.filter { !existing.contains($0) }
                    if !newBranches.isEmpty {
                        updatedRepositories[existingIndex].mrTargetBranches += newBranches
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
