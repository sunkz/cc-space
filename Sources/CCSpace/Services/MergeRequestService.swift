import Foundation

enum MergeRequestService {
    static func createURL(
        repository: RepositoryConfig,
        syncState: RepositorySyncState,
        gitService: GitServicing,
        targetBranch: String? = nil
    ) async throws -> URL {
        let remoteURL = await resolvedRemoteURL(
            repository: repository,
            syncState: syncState,
            gitService: gitService
        )

        guard let sourceBranch = await trimmedCurrentBranch(
            syncState: syncState,
            gitService: gitService
        ) else {
            throw MergeRequestServiceError.missingCurrentBranch
        }

        let resolvedTargetBranch: String
        if let targetBranch {
            resolvedTargetBranch = targetBranch
        } else {
            guard let defaultBranch = await trimmedDefaultBranch(
                remoteURL: remoteURL,
                syncState: syncState,
                gitService: gitService
            ) else {
                throw MergeRequestServiceError.missingDefaultBranch
            }
            resolvedTargetBranch = defaultBranch
        }

        return try GitURLParser.mergeRequestURL(
            from: remoteURL,
            sourceBranch: sourceBranch,
            targetBranch: resolvedTargetBranch
        )
    }
}

private extension MergeRequestService {
    static func resolvedRemoteURL(
        repository: RepositoryConfig,
        syncState: RepositorySyncState,
        gitService: GitServicing
    ) async -> String {
        if let remoteURL = await gitService.remoteURL(in: syncState.localPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           remoteURL.isEmpty == false {
            return remoteURL
        }

        return repository.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func trimmedCurrentBranch(
        syncState: RepositorySyncState,
        gitService: GitServicing
    ) async -> String? {
        let branch = await gitService.currentBranch(in: syncState.localPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let branch, branch.isEmpty == false else { return nil }
        return branch
    }

    static func trimmedDefaultBranch(
        remoteURL: String,
        syncState: RepositorySyncState,
        gitService: GitServicing
    ) async -> String? {
        if let localDefaultBranch = await gitService.defaultBranch(in: syncState.localPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           localDefaultBranch.isEmpty == false {
            return localDefaultBranch
        }

        let remoteDefaultBranch = await gitService.defaultBranch(for: remoteURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteDefaultBranch, remoteDefaultBranch.isEmpty == false else { return nil }
        return remoteDefaultBranch
    }
}

enum MergeRequestServiceError: LocalizedError {
    case missingCurrentBranch
    case missingDefaultBranch

    var errorDescription: String? {
        switch self {
        case .missingCurrentBranch:
            return "无法识别当前分支"
        case .missingDefaultBranch:
            return "无法识别仓库默认分支"
        }
    }
}
