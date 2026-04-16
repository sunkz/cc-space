import Foundation
import os

private let repositoryStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RepositoryStore"
)

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
        }
    }
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

    func updateRepository(id: UUID, gitURL: String) throws {
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
        updatedRepositories[index].updatedAt = .now
        try persistRepositories(updatedRepositories)
    }
}
