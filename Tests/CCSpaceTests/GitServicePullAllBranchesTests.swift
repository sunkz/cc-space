import XCTest
@testable import CCSpace

final class GitServicePullAllBranchesTests: XCTestCase {
    func test_remoteTrackingBranchesListsLocalRemoteRefsWithoutHEAD() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "feature"])
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])

        let service = GitService()
        let branches = await service.remoteTrackingBranches(in: env.clone.path)

        XCTAssertEqual(branches, ["origin/feature", "origin/main"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        // origin/HEAD 这类符号引用不进入列表。
        XCTAssertFalse(branches.contains { $0.hasSuffix("/HEAD") })
    }

    func test_remoteTrackingBranchesExcludesSymbolicHEADEntry() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // clone 默认带 refs/remotes/origin/HEAD 符号引用,short 名为 "origin"。
        let service = GitService()
        let branches = await service.remoteTrackingBranches(in: env.clone.path)

        XCTAssertFalse(branches.contains("origin"))
        XCTAssertTrue(branches.allSatisfy { $0.contains("/") })
    }

    func test_pullAllBranches_singleBranch_fastForwards() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // remote 上添加新 commit
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("extra.txt").path,
            contents: Data("extra".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "extra.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "extra"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "main"])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        XCTAssertEqual(outcome.currentBranch, "main")
        XCTAssertEqual(outcome.currentBranchOutcome?.branch, "main")
        XCTAssertEqual(outcome.currentBranchOutcome?.status, .pulled)
        XCTAssertTrue(outcome.otherBranchOutcomes.isEmpty)
        XCTAssertNil(outcome.primaryError)

        let log = try shell(["git", "-C", env.clone.path, "log", "--oneline"])
        XCTAssertTrue(log.contains("extra"))
    }

    func test_pullAllBranches_otherBranch_fastForwardsWhenBehind() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // 在 source 上创建 feature 分支并推送
        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature init"])
        _ = try shell(["git", "-C", env.source.path, "push", "-u", "origin", "feature"])

        // clone 端建立本地 feature 跟踪分支
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "-b", "feature", "origin/feature"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "main"])

        // source 在 feature 上再加一个 commit 并推送
        _ = try shell(["git", "-C", env.source.path, "checkout", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature2.txt").path,
            contents: Data("feature2".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature2.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature 2"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "feature"])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        XCTAssertEqual(outcome.currentBranch, "main")
        XCTAssertEqual(outcome.otherBranchOutcomes.count, 1)
        let featureOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "feature" })
        XCTAssertEqual(featureOutcome.status, .pulled)

        let log = try shell(["git", "-C", env.clone.path, "log", "feature", "--oneline"])
        XCTAssertTrue(log.contains("feature 2"))
    }

    func test_pullAllBranches_otherBranch_alreadyUpToDate() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature init"])
        _ = try shell(["git", "-C", env.source.path, "push", "-u", "origin", "feature"])
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "-b", "feature", "origin/feature"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "main"])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        let featureOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "feature" })
        XCTAssertEqual(featureOutcome.status, .alreadyUpToDate)
    }

    func test_pullAllBranches_otherBranch_divergedIsSkipped() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature init"])
        _ = try shell(["git", "-C", env.source.path, "push", "-u", "origin", "feature"])
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "-b", "feature", "origin/feature"])

        // clone 端独立 commit
        FileManager.default.createFile(
            atPath: env.clone.appendingPathComponent("local.txt").path,
            contents: Data("local".utf8)
        )
        _ = try shell(["git", "-C", env.clone.path, "add", "local.txt"])
        _ = try shell(["git", "-C", env.clone.path, "commit", "-m", "local-only"])

        // source 端独立 commit 并推送
        _ = try shell(["git", "-C", env.source.path, "checkout", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("remote.txt").path,
            contents: Data("remote".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "remote.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "remote-only"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "feature"])

        // 切回 main 让 feature 不是当前分支
        _ = try shell(["git", "-C", env.clone.path, "checkout", "main"])
        let beforeSHA = try shell(["git", "-C", env.clone.path, "rev-parse", "feature"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        let featureOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "feature" })
        XCTAssertEqual(featureOutcome.status, .skippedDiverged)

        let afterSHA = try shell(["git", "-C", env.clone.path, "rev-parse", "feature"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(beforeSHA, afterSHA, "本地 feature ref 不应被改写")
    }

    func test_pullAllBranches_otherBranch_noUpstreamSkipped() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.clone.path, "checkout", "-b", "local-only"])
        FileManager.default.createFile(
            atPath: env.clone.appendingPathComponent("x.txt").path,
            contents: Data("x".utf8)
        )
        _ = try shell(["git", "-C", env.clone.path, "add", "x.txt"])
        _ = try shell(["git", "-C", env.clone.path, "commit", "-m", "x"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "main"])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        let branchOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "local-only" })
        XCTAssertEqual(branchOutcome.status, .skippedNoUpstream)
    }

    func test_pullAllBranches_detachedHEAD_skipsCurrentButProcessesOthers() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature init"])
        _ = try shell(["git", "-C", env.source.path, "push", "-u", "origin", "feature"])
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "-b", "feature", "origin/feature"])
        _ = try shell(["git", "-C", env.clone.path, "checkout", "main"])
        _ = try shell(["git", "-C", env.source.path, "checkout", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature2.txt").path,
            contents: Data("feature2".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature2.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature 2"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "feature"])

        let mainSHA = try shell(["git", "-C", env.clone.path, "rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try shell(["git", "-C", env.clone.path, "checkout", mainSHA])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        XCTAssertNil(outcome.currentBranch)
        XCTAssertNil(outcome.currentBranchOutcome)
        let featureOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "feature" })
        XCTAssertEqual(featureOutcome.status, .pulled)
    }

    func test_pullAllBranches_fetchFails_throws() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        _ = try shell(["git", "-C", env.clone.path, "remote", "set-url", "origin", "/nonexistent/path.git"])

        let service = GitService()
        do {
            _ = try await service.pullAllBranches(in: env.clone.path)
            XCTFail("应当抛错")
        } catch {
            // pass
        }
    }

    func test_pullAllBranches_currentBranchFails_othersStillProcessed() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // 远端 main 推一个新 commit
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("remote-main.txt").path,
            contents: Data("rm".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "remote-main.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "remote main"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "main"])

        // clone 本地也在 main 上独立写同名文件并提交 → pull 时会 merge 冲突
        FileManager.default.createFile(
            atPath: env.clone.appendingPathComponent("remote-main.txt").path,
            contents: Data("local conflict".utf8)
        )
        _ = try shell(["git", "-C", env.clone.path, "add", "remote-main.txt"])
        _ = try shell(["git", "-C", env.clone.path, "commit", "-m", "local conflicting main"])

        // 同时建一个可以 ff 的 feature 分支:先建本地与 upstream 同步,然后远端再推一个 commit 让本地真正落后
        _ = try shell(["git", "-C", env.source.path, "checkout", "-b", "feature"])
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature.txt").path,
            contents: Data("feature".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature init"])
        _ = try shell(["git", "-C", env.source.path, "push", "-u", "origin", "feature"])
        _ = try shell(["git", "-C", env.clone.path, "fetch", "origin"])
        _ = try shell(["git", "-C", env.clone.path, "branch", "feature", "origin/feature"])

        // 远端 feature 再推一个 commit,本地 feature 落后于 origin/feature
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("feature2.txt").path,
            contents: Data("feature2".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "feature2.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "feature 2"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "feature"])

        let service = GitService()
        let outcome = try await service.pullAllBranches(in: env.clone.path)

        XCTAssertNotNil(outcome.primaryError, "当前分支 main 应失败")
        XCTAssertEqual(outcome.currentBranchOutcome?.status, .failed)
        let featureOutcome = try XCTUnwrap(outcome.otherBranchOutcomes.first { $0.branch == "feature" })
        XCTAssertEqual(featureOutcome.status, .pulled)
    }

    func test_pull_divergedWithoutStrategyConfig_fallsBackToMerge() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // 隔离全局/系统配置,确保 pull.rebase/pull.ff 未配置(否则机器配置会掩盖回退路径)。
        // 保存原值而非简单 unsetenv:那是进程级环境变量,unsetenv 会永久抹掉
        // 本进程原本的配置,污染同进程后续测试。
        // 注意:setenv 仍是进程级——本文件在 XCTest 串行模式下安全;
        // 若将来启用并行测试(XCTest --parallel),不同用例会在同一进程内互相覆盖
        // GIT_CONFIG_*,需要先改为每用例独立 HOME 的方案。
        let originalGlobal = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        let originalSystem = ProcessInfo.processInfo.environment["GIT_CONFIG_SYSTEM"]
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        defer {
            if let originalGlobal {
                setenv("GIT_CONFIG_GLOBAL", originalGlobal, 1)
            } else {
                unsetenv("GIT_CONFIG_GLOBAL")
            }
            if let originalSystem {
                setenv("GIT_CONFIG_SYSTEM", originalSystem, 1)
            } else {
                unsetenv("GIT_CONFIG_SYSTEM")
            }
        }

        // clone 端本地独立 commit
        FileManager.default.createFile(
            atPath: env.clone.appendingPathComponent("local.txt").path,
            contents: Data("local".utf8)
        )
        _ = try shell(["git", "-C", env.clone.path, "add", "local.txt"])
        _ = try shell(["git", "-C", env.clone.path, "commit", "-m", "local-only"])

        // source 端独立 commit 并推送
        FileManager.default.createFile(
            atPath: env.source.appendingPathComponent("remote.txt").path,
            contents: Data("remote".utf8)
        )
        _ = try shell(["git", "-C", env.source.path, "add", "remote.txt"])
        _ = try shell(["git", "-C", env.source.path, "commit", "-m", "remote-only"])
        _ = try shell(["git", "-C", env.source.path, "push", "origin", "main"])

        // 确认该环境下裸 pull 确实被 git 拒绝,否则本测试没有覆盖到回退路径
        let rawPull = try? shell(["git", "-C", env.clone.path, "pull"])
        XCTAssertNil(rawPull, "裸 git pull 在未配置策略时应失败")

        let service = GitService()
        try await service.pull(in: env.clone.path)

        // 回退为合并:HEAD 出现第二个父提交,远端提交已合入
        _ = try shell(["git", "-C", env.clone.path, "rev-parse", "HEAD^2"])
        let log = try shell(["git", "-C", env.clone.path, "log", "--oneline"])
        XCTAssertTrue(log.contains("remote-only"))

        let status = try shell(["git", "-C", env.clone.path, "status", "--porcelain=2", "--branch"])
        XCTAssertTrue(
            status.contains("# branch.ab +2 -0"),
            "落后应清零,领先为本地提交+合并提交:\n\(status)"
        )
    }

    // MARK: - Helpers

    struct TestEnv {
        let root: URL
        let source: URL
        let bare: URL
        let clone: URL
    }

    func makeTestEnvironment() throws -> TestEnv {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let bare = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")

        _ = try shell(["git", "init", "-b", "main", source.path])
        _ = try shell(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", source.path, "config", "user.name", "test"])
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("README.md").path,
            contents: Data("hello".utf8)
        )
        _ = try shell(["git", "-C", source.path, "add", "README.md"])
        _ = try shell(["git", "-C", source.path, "commit", "-m", "init"])
        _ = try shell(["git", "init", "--bare", bare.path])
        _ = try shell(["git", "-C", bare.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try shell(["git", "-C", source.path, "remote", "add", "origin", bare.path])
        _ = try shell(["git", "-C", source.path, "push", "-u", "origin", "main"])
        _ = try shell(["git", "clone", bare.path, clone.path])
        _ = try shell(["git", "-C", clone.path, "config", "user.email", "test@example.com"])
        _ = try shell(["git", "-C", clone.path, "config", "user.name", "test"])
        return TestEnv(root: root, source: source, bare: bare, clone: clone)
    }

    func shell(_ arguments: [String]) throws -> String {
        let task = Process()
        // 固定 /usr/bin/git 并关掉全局配置(gpgsign/hooks)对测试的干扰,
        // 与 GitProcessRunner 的生产探测路径保持一致。
        let gitArguments: [String]
        if arguments.first == "git" {
            gitArguments = ["/usr/bin/git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
                + Array(arguments.dropFirst())
        } else {
            gitArguments = arguments
        }
        task.executableURL = URL(fileURLWithPath: gitArguments[0])
        task.arguments = Array(gitArguments.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        // 先排空管道再等退出:输出超 64KB 时子进程会因管道写满而阻塞,
        // 先 waitUntilExit 会互相等待造成死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(task.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: output
            ])
        }
        return output
    }
}
