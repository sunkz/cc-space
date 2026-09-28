import XCTest
@testable import CCSpace

/// P0 回归:取消后自动暂存必须被恢复。
///
/// `withCleanWorkingTree` 的 body 内含 fetch/merge 等可达 60s 的联网操作,
/// View 在 `onDisappear` 会 cancel 任务。若"恢复 stash"仍留在该已取消任务里执行,
/// `GitProcessRunner` 开头的 `Task.checkCancellation()` 会直接拒绝,本地改动
/// 永远回不到工作区;错误还会被包装成"Stash 栈已被其它操作改动"这类误导文案。
/// 修复靠 `GitWorktreeSafety.restoreStash` 的 `Task.detached`(不继承取消)。
///
/// 本文件用真实 `/usr/bin/git` + UUID 临时目录构造本地仓库,全程不联网。
final class GitWorktreeCancellationRestoreTests: XCTestCase {
    /// 本用例专属的配置隔离环境变量(指向用例临时目录里的空配置文件),
    /// 经子进程 environment 注入,不用 setenv 改进程全局:
    /// 宿主机的 gpgsign/pull.* 等全局配置对测试不可见,系统配置由
    /// `GIT_CONFIG_SYSTEM`(指向空文件;自 git 2.32 起支持,本机 Apple git 实测生效)
    /// 与 `GIT_CONFIG_NOSYSTEM=1` 双重屏蔽——后者作双保险/兼容更旧工具链,
    /// 不依赖单一变量,`git stash` 创建暂存提交时也不会去弹全局签名。
    private var isolationEnvironment: [String: String] = [:]

    private struct DirtyRepositoryEnvironment {
        let root: URL
        let repository: URL
    }

    /// 外层任务被取消:body 挂起期间收到 cancel。
    /// 断言:① stash 已恢复(改动回工作区、stash 栈为空);② 抛出的错误准确,
    /// 且 `UserFacingError.message(for:)` 是中文「操作已取消」。
    func test_cancelDuringBodyRestoresStashAndReportsChineseCancellation() async throws {
        let env = try makeDirtyRepository()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let service = GitService(additionalEnvironment: isolationEnvironment)
        // 流的第一个元素 = body 已开始 + 暂存是否已生效;
        // body 未开始就结束(前置步骤失败)时流直接 finish,next() 返回 nil。
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let task = Task<Void, Error> {
            defer { continuation.finish() }
            try await GitWorktreeSafety.withCleanWorkingTree(
                in: env.repository.path,
                gitService: service,
                blockedOperation: .switchBranch
            ) {
                // 暂存生效时工作区应已回到 HEAD(README 是提交时的内容)。
                let readme = env.repository.appendingPathComponent("README.md")
                let stashedCleanly =
                    ((try? String(contentsOf: readme, encoding: .utf8)) ?? "") == "committed\n"
                continuation.yield(stashedCleanly)
                // 模拟 body 内的联网操作:挂起等待,随后被外层 cancel 打断。
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }

        var iterator = stream.makeAsyncIterator()
        guard let stashedDuringBody = await iterator.next() else {
            _ = try? await task.value
            XCTFail("body 未开始就结束了(前置的自动暂存步骤失败?)")
            return
        }
        XCTAssertTrue(stashedDuringBody, "body 执行期间本地改动必须已被自动暂存")

        task.cancel()

        var thrown: Error?
        do {
            try await task.value
        } catch {
            thrown = error
        }
        let error = try XCTUnwrap(thrown, "取消后 withCleanWorkingTree 应当抛错")

        // ① stash 已恢复:本地改动回到工作区,stash 栈不残留。
        let restored = try String(
            contentsOf: env.repository.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "dirty change\n", "取消后本地改动必须回到工作区")
        let stashEntries = await service.stashList(in: env.repository.path)
        XCTAssertTrue(stashEntries.isEmpty, "自动暂存必须已弹出,不得滞留 stash 栈")

        // ② 错误准确:原样上抛取消错误,而不是恢复失败的包装/误导文案。
        XCTAssertTrue(error is CancellationError, "应原样上抛 CancellationError,实际:\(error)")
        XCTAssertFalse(
            "\(error)".contains("Stash 栈已被其它操作改动"),
            "不得把取消误报成 stash 栈错位"
        )
        XCTAssertEqual(UserFacingError.message(for: error), "操作已取消")
    }

    /// body 自己抛出 CancellationError,且**承载 withCleanWorkingTree 的任务此刻已被
    /// cancel**(外层取消先到,body 观察到后再手动抛)。
    ///
    /// 这才是本用例的判别力所在:抛出时任务已处于取消态,恢复 stash 因此跑在一个
    /// 已取消的任务里;没有 `Task.detached` 脱离取消上下文的修复时,
    /// `GitProcessRunner` 开头的 `Task.checkCancellation()` 会拒绝恢复,
    /// 改动永远回不到工作区。(上一条用例覆盖的是「外层 cancel 直接打断 body 挂起」。)
    func test_bodyThrowingCancellationStillRestoresStash() async throws {
        let env = try makeDirtyRepository()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let service = GitService(additionalEnvironment: isolationEnvironment)
        // 单独的外层任务:取消只作用在它身上,测试自己的任务保持未取消,
        // 后续 stashList 等断言照常执行(被取消的任务里 git 探测会全部快速失败)。
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let task = Task<Void, Error> {
            defer { continuation.finish() }
            try await GitWorktreeSafety.withCleanWorkingTree(
                in: env.repository.path,
                gitService: service,
                blockedOperation: .switchBranch
            ) {
                continuation.yield(true)
                // 挂起等外层 cancel(轮询上限 5s 仅为信号丢失时兜底,避免用例挂死)。
                var pollsLeft = 500
                while pollsLeft > 0 && !Task.isCancelled {
                    _ = try? await Task.sleep(nanoseconds: 10_000_000)
                    pollsLeft -= 1
                }
                // 取消已生效,由 body 自己抛出 CancellationError。
                throw CancellationError()
            }
        }

        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() == true else {
            // body 未开始(前置的自动暂存步骤失败):先取消再等,避免兜底循环空转。
            task.cancel()
            _ = try? await task.value
            XCTFail("body 未开始就结束了(前置的自动暂存步骤失败?)")
            return
        }
        task.cancel()

        var thrown: Error?
        do {
            try await task.value
        } catch {
            thrown = error
        }
        let error = try XCTUnwrap(thrown, "body 抛错时应原样上抛")

        let restored = try String(
            contentsOf: env.repository.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "dirty change\n", "body 抛错后本地改动必须回到工作区")
        let stashEntries = await service.stashList(in: env.repository.path)
        XCTAssertTrue(stashEntries.isEmpty, "自动暂存必须已弹出,不得滞留 stash 栈")
        XCTAssertTrue(error is CancellationError, "应原样上抛 CancellationError,实际:\(error)")
        XCTAssertEqual(UserFacingError.message(for: error), "操作已取消")
    }

    // MARK: - 夹具

    /// 建"已提交 + 跟踪文件已修改"的本地仓库(工作区不干净,
    /// `withCleanWorkingTree` 走自动暂存路径)。真实 /usr/bin/git,不联网。
    private func makeDirtyRepository() throws -> DirtyRepositoryEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let globalConfig = root.appendingPathComponent("gitconfig")
        let systemConfig = root.appendingPathComponent("system-gitconfig")
        try Data().write(to: globalConfig)
        try Data().write(to: systemConfig)
        isolationEnvironment = [
            "GIT_CONFIG_GLOBAL": globalConfig.path,
            "GIT_CONFIG_SYSTEM": systemConfig.path,
            // 系统配置再叠 GIT_CONFIG_NOSYSTEM=1(git 原生的"禁读系统配置"开关),
            // 与 GIT_CONFIG_SYSTEM 指向空文件互为兜底,credential.helper 等也进不来。
            "GIT_CONFIG_NOSYSTEM": "1",
        ]

        let repository = root.appendingPathComponent("repo")
        _ = try ShellHelper.run(["git", "init", "-b", "main", repository.path], environment: isolationEnvironment)
        _ = try ShellHelper.run(
            ["git", "-C", repository.path, "config", "user.email", "test@example.com"],
            environment: isolationEnvironment
        )
        _ = try ShellHelper.run(
            ["git", "-C", repository.path, "config", "user.name", "test"],
            environment: isolationEnvironment
        )
        let readme = repository.appendingPathComponent("README.md")
        try Data("committed\n".utf8).write(to: readme)
        _ = try ShellHelper.run(["git", "-C", repository.path, "add", "README.md"], environment: isolationEnvironment)
        _ = try ShellHelper.run(["git", "-C", repository.path, "commit", "-m", "init"], environment: isolationEnvironment)
        // 制造跟踪文件的未提交修改:进入 body 前工作区必须不干净。
        try Data("dirty change\n".utf8).write(to: readme)
        return DirtyRepositoryEnvironment(root: root, repository: repository)
    }
}
