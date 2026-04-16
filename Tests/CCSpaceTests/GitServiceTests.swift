import XCTest
@testable import CCSpace

final class GitServiceTests: XCTestCase {
    func test_checkoutBranchSwitchesToExistingLocalBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", repository.path, "checkout", "-b", "feature/demo"])
        _ = try shell(["git", "-C", repository.path, "checkout", "main"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: repository.path)

        let currentBranch = await service.currentBranch(in: repository.path)
        XCTAssertEqual(currentBranch, "feature/demo")
    }

    func test_checkoutBranchCreatesTrackingBranchFromRemoteWhenLocalBranchMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/demo"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/demo"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "checkout", "main"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: clone.path)

        let currentBranch = await service.currentBranch(in: clone.path)
        let branchesOutput = try shell(["git", "-C", clone.path, "branch", "--list", "feature/demo"])

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertTrue(branchesOutput.contains("feature/demo"))
    }

    func test_checkoutBranchFetchesRemoteBranchWhenOriginReferenceIsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])

        _ = try shell(["git", "-C", source.path, "checkout", "-b", "feature/demo"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("FEATURE.md").path,
            contents: Data("remote branch".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "FEATURE.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "feature"])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "feature/demo"])

        let staleRemoteBranch = try shell(["git", "-C", clone.path, "branch", "-r", "--list", "origin/feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(staleRemoteBranch.isEmpty)

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: clone.path)

        let currentBranch = await service.currentBranch(in: clone.path)
        let localHead = try shell(["git", "-C", clone.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFeatureHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainHead = try shell(["git", "-C", clone.path, "rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertEqual(localHead, remoteFeatureHead)
        XCTAssertNotEqual(localHead, mainHead)
    }

    func test_checkoutBranchCreatesLocalBranchFromCurrentHeadWhenRemoteBranchMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo")

        _ = try shell(["git", "init", repository.path])
        _ = try shell(["git", "-C", repository.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", repository.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", repository.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: repository.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", repository.path, "add", "README.md"])
        _ = try shell(["git", "-C", repository.path, "commit", "-m", "init"])

        let service = GitService()
        try await service.checkoutBranch("feature/demo", in: repository.path)

        let currentBranch = await service.currentBranch(in: repository.path)
        let featureHead = try shell(["git", "-C", repository.path, "rev-parse", "feature/demo"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainHead = try shell(["git", "-C", repository.path, "rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(currentBranch, "feature/demo")
        XCTAssertEqual(featureHead, mainHead)
    }

    func test_defaultBranchUsesLocalOriginHeadReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])

        let service = GitService()
        let defaultBranch = await service.defaultBranch(in: clone.path)

        XCTAssertEqual(defaultBranch, "main")
    }

    func test_pushSetsUpstreamWhenCurrentBranchHasNoTrackingBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])

        let service = GitService()
        try await service.push(in: source.path)

        let upstream = try shell([
            "git", "-C", source.path,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localHead = try shell(["git", "-C", source.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(upstream, "origin/main")
        XCTAssertEqual(remoteHead, localHead)
    }

    func test_pushUsesExistingTrackingBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bareRemote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        _ = try shell(["git", "-C", source.path, "branch", "-m", "main"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bareRemote.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "-C", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "clone", bareRemote.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", clone.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: clone.appendingPathComponent("README.md").path,
            contents: Data("updated".utf8)
        )
        _ = try shell(["git", "-C", clone.path, "add", "README.md"])
        _ = try shell(["git", "-C", clone.path, "commit", "-m", "update"])

        let service = GitService()
        try await service.push(in: clone.path)

        let remoteHead = try shell(["git", "-C", bareRemote.path, "rev-parse", "refs/heads/main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localHead = try shell(["git", "-C", clone.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(remoteHead, localHead)
    }

    private func shell(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "command failed: \(arguments.joined(separator: " "))\n\(stderr)"]
            )
        }

        return stdout
    }
}
