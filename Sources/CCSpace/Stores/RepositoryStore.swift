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

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        do {
            self.repositories = try fileStore.loadIfPresent([RepositoryConfig].self, from: "repositories.json", default: [])
        } catch {
            repositoryStoreLog.error("event=load_repositories_failed reason=\(error.localizedDescription)")
            didRecoverFromCorruptFile = true
            // 先逐元素容错抢救再保全原文件:preserveCorruptFile 会改名/复制原文件,
            // 放到后面就读不到原始内容了。单条坏记录不该让整个仓库列表报废。
            if let tolerated = fileStore.loadArrayToleratingBadElements(
                RepositoryConfig.self,
                from: "repositories.json"
            ) {
                self.repositories = tolerated.values
                repositoryStoreLog.error("event=recovered_partial_repositories kept=\(tolerated.values.count) dropped=\(tolerated.droppedCount)")
            } else {
                self.repositories = []
            }
            fileStore.preserveCorruptFile(named: "repositories.json")
        }
    }

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

    private func makeBackupDecoder() -> JSONDecoder {
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

    nonisolated private static func gitURLsMatch(_ lhs: String, _ rhs: String) -> Bool {
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
            repositoryStoreLog.notice(
                "event=deduplication_removed count=\(removedNames.count) names=\(removedNames.joined(separator: ","), privacy: .private)"
            )
        } catch {
            repositoryStoreLog.error("event=deduplication_save_failed reason=\(error.localizedDescription)")
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
        // 保留优先级排序:被工作区/同步态引用者 > createdAt 更早者 > 其余。
        // 旧逻辑按数组顺序"保留第一条、硬删其余",可能删掉的恰是被工作区引用的
        // 那条而留下新添加的重复记录——工作区静默丢仓库。结果仍按原数组顺序输出,
        // 不改变列表展示序。
        let prioritySorted = repositories.sorted { lhs, rhs in
            let lhsProtected = protectedRepositoryIDs.contains(lhs.id)
            let rhsProtected = protectedRepositoryIDs.contains(rhs.id)
            if lhsProtected != rhsProtected { return lhsProtected }
            return lhs.createdAt < rhs.createdAt
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
        return document
    }

    func importBackup(from fileURL: URL) throws -> RepositoryImportResult {
        let data = try Data(contentsOf: fileURL)
        let decoder = makeBackupDecoder()

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

        guard version <= RepositoryBackupDocument.currentVersion else {
            throw RepositoryStoreError.unsupportedBackupVersion(version)
        }

        let cleanedEntries = entries.filter {
            !$0.gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleanedEntries.isEmpty else {
            throw RepositoryStoreError.emptyBackup
        }

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
                repositoryStoreLog.error("event=import_entry_rejected index=\(entryIndex)")
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
