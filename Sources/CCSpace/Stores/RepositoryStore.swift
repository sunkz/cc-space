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

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        self.repositories =
            (try? fileStore.loadIfPresent([RepositoryConfig].self, from: "repositories.json", default: [])) ?? []
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeBackupDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func addRepository(gitURL: String) throws {
        let normalizedGitURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard repositories.contains(where: { $0.gitURL == normalizedGitURL }) == false else {
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

    func removeRepository(id: UUID, workplaceStore: WorkplaceStore? = nil) throws {
        let updatedRepositories = repositories.filter { $0.id != id }
        try persistRepositories(updatedRepositories)

        if let workplaceStore {
            workplaceStore.removeRepositoryAssociations(repositoryID: id)
        }
    }

    func deduplicatePersistedRepositories() {
        applyDeduplicationResult(Self.deduplicationResult(for: repositories))
    }

    func applyDeduplicationResult(_ result: RepositoryDeduplicationResult) {
        guard result.changed else { return }
        do {
            try persistRepositories(result.repositories)
        } catch {
            repositoryStoreLog.error("event=deduplication_save_failed reason=\(error.localizedDescription)")
        }
    }

    nonisolated static func deduplicationResult(for repositories: [RepositoryConfig]) -> RepositoryDeduplicationResult {
        var existingURLs = Set<String>()
        var existingNames = Set<String>()
        var changed = false

        let deduplicatedRepositories = repositories.filter { repository in
            if existingURLs.contains(repository.gitURL) || existingNames.contains(repository.repoName) {
                changed = true
                return false
            }
            existingURLs.insert(repository.gitURL)
            existingNames.insert(repository.repoName)
            return true
        }

        return RepositoryDeduplicationResult(
            repositories: deduplicatedRepositories,
            changed: changed
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

        guard !repositories.contains(where: { $0.id != id && $0.gitURL == normalizedGitURL }) else {
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

        for entry in cleanedEntries {
            let gitURL = entry.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let repoName = try validatedRepositoryName(from: gitURL)

            if let existingIndex = updatedRepositories.firstIndex(where: { $0.gitURL == gitURL }) {
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
