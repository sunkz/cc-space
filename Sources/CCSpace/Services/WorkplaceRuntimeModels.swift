import Foundation

enum WorkplaceRuntimeServiceError: LocalizedError {
    case missingLocalRepository
    case emptyBranch
    case noLocalRepositories
    case missingRemoteRepository
    case missingDefaultBranch
    case unreadableGitStatus

    var errorDescription: String? {
        switch self {
        case .missingLocalRepository:
            return "仓库本地目录不存在"
        case .emptyBranch:
            return "分支名不能为空"
        case .noLocalRepositories:
            return "当前工作区没有已克隆的本地仓库"
        case .missingRemoteRepository:
            return "仓库未配置 origin 远端"
        case .missingDefaultBranch:
            return "无法识别仓库默认分支"
        case .unreadableGitStatus:
            return "无法读取仓库 Git 状态"
        }
    }
}

enum WorkplaceDeletionError: LocalizedError, Equatable {
    case unmanagedPath(workplacePath: String, rootPath: String)
    case directoryBusy(path: String)
    case permissionDenied(path: String)
    case removalFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unmanagedPath(let workplacePath, let rootPath):
            return """
            当前工作区目录不在已配置的根目录内，删除按钮默认会连同本地目录一起删除，因此被安全拦截。
            根目录：\(rootPath)
            工作区目录：\(workplacePath)
            """
        case .directoryBusy(let path):
            return """
            工作区目录正在被其他程序使用，请关闭占用该目录的终端、IDE 或本地服务后重试。
            目录：\(path)
            """
        case .permissionDenied(let path):
            return """
            没有权限删除工作区目录，请检查目录权限后重试。
            目录：\(path)
            """
        case .removalFailed(let path, let reason):
            return """
            无法删除工作区目录。
            目录：\(path)
            原因：\(reason)
            """
        }
    }

    static func fromRemovalError(
        _ error: Error,
        path: String
    ) -> WorkplaceDeletionError {
        let relevantErrors = [error as NSError] + (error as NSError).underlyingErrors

        if relevantErrors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == EBUSY }) {
            return .directoryBusy(path: path)
        }

        if relevantErrors.contains(where: {
            ($0.domain == NSPOSIXErrorDomain && ($0.code == EACCES || $0.code == EPERM)) ||
                ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteNoPermission.rawValue)
        }) {
            return .permissionDenied(path: path)
        }

        return .removalFailed(
            path: path,
            reason: error.localizedDescription
        )
    }
}

struct WorkplaceBulkBranchSwitchResult: Equatable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int

    init(successCount: Int, failedCount: Int, skippedCount: Int = 0) {
        self.successCount = successCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
    }

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

struct RepositoryPushResult: Equatable {
    let successCount: Int
    let failedCount: Int
    let skippedCount: Int

    var attemptedCount: Int {
        successCount + failedCount + skippedCount
    }
}

enum RepositoryPushOutcome: Equatable {
    case pushed
    case skipped
}

enum BatchPushOperationResult: Sendable {
    case pushed(RepositorySyncState)
    case skipped(RepositorySyncState)
    case failed(RepositorySyncState)
}

enum BatchBranchSwitchOperationResult: Sendable {
    case success(RepositorySyncState)
    case failed(RepositorySyncState)
}

enum BatchBranchResolutionResult: Sendable {
    case success(String)
    case failure(String)
}

enum BatchMergeOperationResult: Sendable {
    case merged(RepositorySyncState)
    case skipped(RepositorySyncState)
    case failed(RepositorySyncState)
}

extension BatchPushOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .pushed(let state), .skipped(let state), .failed(let state):
            return state
        }
    }

    var isPushed: Bool {
        if case .pushed = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension BatchBranchSwitchOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .success(let state), .failed(let state):
            return state
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension BatchMergeOperationResult {
    var updatedState: RepositorySyncState {
        switch self {
        case .merged(let state), .skipped(let state), .failed(let state):
            return state
        }
    }

    var isMerged: Bool {
        if case .merged = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension NSError {
    var underlyingErrors: [NSError] {
        var collected: [NSError] = []

        if let direct = userInfo[NSUnderlyingErrorKey] as? NSError {
            collected.append(direct)
            collected.append(contentsOf: direct.underlyingErrors)
        }

        return collected
    }
}
