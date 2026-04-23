import Foundation

protocol GitServicing: Sendable {
    func clone(repositoryURL: String, into directory: String) async throws
    func pull(in directory: String) async throws
    func push(in directory: String) async throws
    func isGitAvailable() async -> Bool
    func defaultBranch(for remoteURL: String) async -> String?
    func defaultBranch(in directory: String) async -> String?
    func currentBranch(in directory: String) async -> String?
    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot?
    func branches(in directory: String) async -> [String]
    func remoteURL(in directory: String) async -> String?
    func checkoutBranch(_ branch: String, in directory: String) async throws
    func createLocalBranch(_ branch: String, in directory: String) async throws
    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool
    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig]
    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome
    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry]
}

struct GitCommitEntry: Identifiable, Equatable {
    let hash: String
    let subject: String
    let author: String
    let date: Date

    var id: String { hash }

    var shortHash: String {
        String(hash.prefix(7))
    }
}

enum GitMergeDefaultBranchOutcome: Equatable {
    case merged
    case skipped
}

struct GitBranchStatusSnapshot: Equatable {
    let currentBranch: String?
    let hasRemoteTrackingBranch: Bool
    let hasUncommittedChanges: Bool
    let hasUnpushedCommits: Bool
    let isBehindRemote: Bool

    var isClean: Bool {
        hasUncommittedChanges == false &&
        hasUnpushedCommits == false &&
        isBehindRemote == false &&
        hasRemoteTrackingBranch
    }

    static func parsePorcelainV2(_ output: String) -> GitBranchStatusSnapshot {
        var currentBranch: String?
        var hasRemoteTrackingBranch = false
        var aheadCount = 0
        var behindCount = 0
        var hasUncommittedChanges = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                if value != "(detached)" {
                    currentBranch = value
                }
                continue
            }

            if line.hasPrefix("# branch.upstream ") {
                hasRemoteTrackingBranch = true
                continue
            }

            if line.hasPrefix("# branch.ab ") {
                let components = line
                    .dropFirst("# branch.ab ".count)
                    .split(separator: " ")
                for component in components {
                    if component.hasPrefix("+") {
                        aheadCount = Int(component.dropFirst()) ?? 0
                    } else if component.hasPrefix("-") {
                        behindCount = Int(component.dropFirst()) ?? 0
                    }
                }
                continue
            }

            if line.hasPrefix("#") == false {
                hasUncommittedChanges = true
            }
        }

        return GitBranchStatusSnapshot(
            currentBranch: currentBranch,
            hasRemoteTrackingBranch: hasRemoteTrackingBranch,
            hasUncommittedChanges: hasUncommittedChanges,
            hasUnpushedCommits: aheadCount > 0,
            isBehindRemote: behindCount > 0
        )
    }
}

enum GitWorktreeBlockedOperation: Equatable, Sendable {
    case switchBranch
    case mergeDefaultBranchIntoCurrent
}

enum GitWorktreeSafetyError: LocalizedError, Equatable, Sendable {
    case unreadableStatus
    case uncommittedChanges(blockedOperation: GitWorktreeBlockedOperation)

    var errorDescription: String? {
        switch self {
        case .unreadableStatus:
            return "无法读取仓库 Git 状态"
        case .uncommittedChanges(let blockedOperation):
            switch blockedOperation {
            case .switchBranch:
                return "仓库有未提交的改动，无法切换分支"
            case .mergeDefaultBranchIntoCurrent:
                return "仓库有未提交的改动，无法合并默认分支"
            }
        }
    }
}

enum GitWorktreeSafety {
    static func validateCleanWorkingTree(
        in directory: String,
        gitService: GitServicing,
        blockedOperation: GitWorktreeBlockedOperation
    ) async throws {
        guard let branchStatus = await gitService.branchStatus(in: directory) else {
            throw GitWorktreeSafetyError.unreadableStatus
        }
        guard branchStatus.hasUncommittedChanges == false else {
            throw GitWorktreeSafetyError.uncommittedChanges(blockedOperation: blockedOperation)
        }
    }
}

struct GitService: GitServicing {
    private static let maxConcurrentRemoteBranchChecks = 4

    func clone(repositoryURL: String, into directory: String) async throws {
        try await runGit(arguments: ["clone", repositoryURL, directory], timeout: 300)
    }

    func pull(in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "pull"])
    }

    func push(in directory: String) async throws {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }

        if await trackingBranch(in: directory) != nil {
            try await runGit(arguments: ["-C", directory, "push"])
            return
        }

        guard await remoteURL(in: directory) != nil else {
            throw gitOperationError("仓库未配置 origin 远端")
        }

        try await runGit(arguments: ["-C", directory, "push", "-u", "origin", "--", currentBranch])
    }

    func defaultBranch(for remoteURL: String) async -> String? {
        guard let output = try? await runGitOutput(arguments: ["ls-remote", "--symref", remoteURL, "HEAD"]) else {
            return nil
        }
        return parseDefaultBranch(lsRemoteOutput: output)
    }

    func defaultBranch(in directory: String) async -> String? {
        if let output = try? await runGitOutput(arguments: [
            "-C", directory,
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ]) {
            let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.hasPrefix("origin/") {
                return String(ref.dropFirst("origin/".count))
            }
        }

        guard let remoteURL = await remoteURL(in: directory) else {
            return nil
        }
        return await defaultBranch(for: remoteURL)
    }

    func currentBranch(in directory: String) async -> String? {
        guard let output = try? await runGitOutput(arguments: ["-C", directory, "branch", "--show-current"]) else {
            return nil
        }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    func branchStatus(in directory: String) async -> GitBranchStatusSnapshot? {
        guard let output = try? await runGitOutput(arguments: [
            "-C", directory,
            "status",
            "--porcelain=2",
            "--branch",
        ]) else {
            return nil
        }
        return GitBranchStatusSnapshot.parsePorcelainV2(output)
    }

    func branches(in directory: String) async -> [String] {
        guard let output = try? await runGitOutput(arguments: [
            "-C", directory,
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
        ]) else {
            return []
        }

        let branches = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { branch in
                branch.isEmpty == false &&
                branch != "HEAD"
            }

        return Array(Set(branches)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func remoteURL(in directory: String) async -> String? {
        guard let output = try? await runGitOutput(arguments: ["-C", directory, "remote", "get-url", "origin"]) else {
            return nil
        }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    func checkoutBranch(_ branch: String, in directory: String) async throws {
        do {
            try await runGit(arguments: ["-C", directory, "checkout", branch])
            return
        } catch {
            if try await checkoutRemoteTrackingBranchIfAvailable(branch, in: directory) {
                return
            }

            try await createLocalBranch(branch, in: directory)
        }
    }

    func createLocalBranch(_ branch: String, in directory: String) async throws {
        try await runGit(arguments: ["-C", directory, "checkout", "-b", branch, "--"])
    }

    func remoteBranchExists(branch: String, remoteURL: String) async -> Bool {
        guard let output = try? await runGitOutput(arguments: [
            "ls-remote", "--heads", remoteURL, "refs/heads/\(branch)",
        ]) else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func checkRemoteBranches(branch: String, repositories: [RepositoryConfig]) async -> [RepositoryConfig] {
        await withTaskGroup(of: RepositoryConfig?.self) { group in
            let initialTaskCount = min(Self.maxConcurrentRemoteBranchChecks, repositories.count)
            var nextRepositoryIndex = 0

            func addTask(for repository: RepositoryConfig) {
                group.addTask {
                    let exists = await remoteBranchExists(
                        branch: branch,
                        remoteURL: repository.gitURL
                    )
                    return exists ? repository : nil
                }
            }

            for _ in 0..<initialTaskCount {
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }

            var result: [RepositoryConfig] = []
            while let repo = await group.next() {
                if let repo { result.append(repo) }
                guard Task.isCancelled == false else {
                    group.cancelAll()
                    continue
                }
                guard nextRepositoryIndex < repositories.count else { continue }
                let repository = repositories[nextRepositoryIndex]
                nextRepositoryIndex += 1
                addTask(for: repository)
            }
            return result
        }
    }

    func mergeDefaultBranchIntoCurrent(in directory: String) async throws -> GitMergeDefaultBranchOutcome {
        guard let currentBranch = await currentBranch(in: directory) else {
            throw gitOperationError("无法识别当前分支")
        }
        guard let defaultBranch = await defaultBranch(in: directory) else {
            throw gitOperationError("无法识别仓库默认分支")
        }
        guard currentBranch != defaultBranch else {
            return .skipped
        }

        try await runGit(arguments: ["-C", directory, "fetch", "origin", "--", defaultBranch])
        try await runGit(arguments: ["-C", directory, "merge", "--no-edit", "--", "origin/\(defaultBranch)"])
        return .merged
    }

    func recentCommits(in directory: String, count: Int) async -> [GitCommitEntry] {
        let separator = "<<CCSPACE_SEP>>"
        let format = ["%H", "%s", "%an", "%aI"].joined(separator: separator)
        guard let output = try? await runGitOutput(arguments: [
            "-C", directory,
            "log",
            "--format=\(format)",
            "-\(count)",
        ]) else {
            return []
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> GitCommitEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { return nil }
                let parts = trimmed.components(separatedBy: separator)
                guard parts.count == 4 else { return nil }
                let date = dateFormatter.date(from: parts[3]) ?? .distantPast
                return GitCommitEntry(
                    hash: parts[0],
                    subject: parts[1],
                    author: parts[2],
                    date: date
                )
            }
    }

    func isGitAvailable() async -> Bool {
        return (try? await runGitOutput(arguments: ["--version"])) != nil
    }

    private func trackingBranch(in directory: String) async -> String? {
        guard let output = try? await runGitOutput(arguments: [
            "-C", directory,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ]) else {
            return nil
        }

        let trackingBranch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trackingBranch.isEmpty ? nil : trackingBranch
    }

    private func checkoutRemoteTrackingBranchIfAvailable(
        _ branch: String,
        in directory: String
    ) async throws -> Bool {
        do {
            try await runGit(arguments: [
                "-C", directory,
                "checkout",
                "--track",
                "origin/\(branch)",
            ])
            return true
        } catch {
            guard await remoteURL(in: directory) != nil else {
                return false
            }

            do {
                try await fetchRemoteBranchReference(branch, in: directory)
                try await runGit(arguments: [
                    "-C", directory,
                    "checkout",
                    "--track",
                    "origin/\(branch)",
                ])
                return true
            } catch {
                if isMissingRemoteBranchError(error) {
                    return false
                }
                throw error
            }
        }
    }

    private func fetchRemoteBranchReference(
        _ branch: String,
        in directory: String
    ) async throws {
        try await runGit(arguments: [
            "-C", directory,
            "fetch",
            "origin",
            "refs/heads/\(branch):refs/remotes/origin/\(branch)",
        ])
    }

    private func isMissingRemoteBranchError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("couldn't find remote ref") ||
            message.contains("could not find remote ref") ||
            message.contains("remote ref does not exist") ||
            message.contains("is not a commit and a branch") ||
            message.contains("invalid reference")
    }

    private func runGitOutput(arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        let result = try await runProcess(arguments: arguments, captureStdout: true, captureStderr: true, timeout: timeout)
        guard result.terminationStatus == 0 else {
            let stderrMessage = String(data: result.stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderrMessage.isEmpty ? "git 执行失败" : stderrMessage
            throw NSError(
                domain: "GitService",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return String(data: result.stdoutData, encoding: .utf8) ?? ""
    }

    private func runGit(arguments: [String], timeout: TimeInterval = 60) async throws {
        let result = try await runProcess(arguments: arguments, captureStdout: false, captureStderr: true, timeout: timeout)
        guard result.terminationStatus == 0 else {
            let stderrMessage = String(data: result.stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderrMessage.isEmpty ? "git 执行失败" : stderrMessage
            throw NSError(
                domain: "GitService",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func runProcess(
        arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool,
        timeout: TimeInterval = 60
    ) async throws -> GitProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        process.environment = environment

        let stdoutPipe = captureStdout ? Pipe() : nil
        let stderrPipe = captureStderr ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        process.standardError = stderrPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let processBox = SendableProcessBox(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdoutBox = SendableDataBox()
                let stderrBox = SendableDataBox()
                let readGroup = DispatchGroup()

                if let pipe = stdoutPipe {
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stdoutBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                }

                if let pipe = stderrPipe {
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stderrBox.data = pipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                }

                nonisolated(unsafe) let timeoutWork = DispatchWorkItem { [processBox] in
                    guard processBox.process.isRunning else { return }
                    processBox.process.terminate()
                }

                process.terminationHandler = { completedProcess in
                    timeoutWork.cancel()
                    readGroup.notify(queue: .global()) {
                        continuation.resume(
                            returning: GitProcessResult(
                                terminationStatus: completedProcess.terminationStatus,
                                stdoutData: stdoutBox.data,
                                stderrData: stderrBox.data
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    timeoutWork.cancel()
                    stdoutPipe?.fileHandleForReading.closeFile()
                    stderrPipe?.fileHandleForReading.closeFile()
                    continuation.resume(throwing: error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
            stdoutPipe?.fileHandleForReading.closeFile()
            stderrPipe?.fileHandleForReading.closeFile()
        }
    }

    private func parseDefaultBranch(lsRemoteOutput output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("ref:"), line.contains("HEAD") {
                let parts = line.components(separatedBy: "ref: refs/heads/")
                if parts.count > 1 {
                    return parts[1].components(separatedBy: "\t").first
                }
            }
        }
        return nil
    }

    private func gitOperationError(_ message: String) -> NSError {
        NSError(
            domain: "GitService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct GitProcessResult {
    let terminationStatus: Int32
    let stdoutData: Data
    let stderrData: Data
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class SendableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }
}
