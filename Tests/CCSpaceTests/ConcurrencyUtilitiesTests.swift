import XCTest
@testable import CCSpace

final class ConcurrencyUtilitiesTests: XCTestCase {
    func test_withLockReleasesOnThrowAllowingSubsequentAcquire() async throws {
        let lock = RepositoryOperationLock()
        struct LockedError: Error {}

        do {
            try await lock.withLock(path: "/tmp/repo-a") { () -> Void in
                throw LockedError()
            }
            XCTFail("应抛出 LockedError")
        } catch is LockedError {}

        // 抛错后锁必须已释放:再次获取同一路径不应永久等待。
        let acquired = LockAcquisitionProbe()
        try await lock.withLock(path: "/tmp/repo-a") {
            acquired.markAcquired()
        }
        let didAcquire = acquired.value
        XCTAssertTrue(didAcquire, "抛错释放后应能再次获取锁")
    }

    func test_acquireThrowsWhenCancelledWhileWaiting() async throws {
        let lock = RepositoryOperationLock()
        try await lock.acquire(path: "/tmp/repo-b")

        let waiter = Task { try await lock.acquire(path: "/tmp/repo-b") }
        // 让等待任务先注册进 waiters。
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("等待锁的任务被取消时应抛 CancellationError")
        } catch is CancellationError {}

        await lock.release(path: "/tmp/repo-b")
    }

    func test_withLockPathsBlocksSinglePathAcquireOnAnyMember() async throws {
        let lock = RepositoryOperationLock()
        let root = "/tmp/ws/root"
        let child = "/tmp/ws/root/repo-a"
        let waiterFinished = WaitFlag()

        try await lock.withLockPaths([child, root]) {
            // 锁 key 精确匹配:批量持锁期间,树内任一路径的单独获取都必须被挡住,
            // 这正是"删除整棵工作区"与仓库级 pull/push 互斥的机制。
            let waiter = Task {
                try? await lock.acquire(path: child)
                await waiterFinished.mark()
            }
            // 非阻塞轮询一小段:期间 waiter 绝不能完成(完成=死锁/漏互斥)。
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let finishedEarly = await waiterFinished.isSet()
            XCTAssertFalse(finishedEarly, "批量持锁期间单独获取树内路径应被阻塞")
            waiter.cancel()
            await waiter.value
        }

        // 批量释放后,树内路径必须可再次获取(不永久占锁)。
        try await lock.withLock(path: child) { () -> Void in }
        try await lock.withLock(path: root) { () -> Void in }
    }

    func test_withLockPathsReleasesAllOnThrow() async throws {
        let lock = RepositoryOperationLock()
        struct BatchLockedError: Error {}

        do {
            try await lock.withLockPaths(["/tmp/ws/b", "/tmp/ws/a"]) { () -> Void in
                throw BatchLockedError()
            }
            XCTFail("应抛出 BatchLockedError")
        } catch is BatchLockedError {}

        // 抛错后所有成员路径必须已释放。
        try await lock.withLock(path: "/tmp/ws/a") { () -> Void in }
        try await lock.withLock(path: "/tmp/ws/b") { () -> Void in }
    }

    func test_runLimitedTasksPreservesInputOrder() async {
        let inputs = Array(0..<50)
        let results = await ConcurrencyUtilities.runLimitedTasks(
            inputs,
            maxConcurrentTasks: 8
        ) { value in
            // 用不均匀延迟打乱完成顺序。
            try? await Task.sleep(for: .milliseconds((value % 7) * 5))
            return value * 2
        }

        XCTAssertEqual(results, inputs.map { $0 * 2 })
    }

    /// 回归锁:父任务执行中途取消时,**所有**输入都必须仍产出结果。
    /// 调用方(如 pullRepositories)会先把全部行预标成 .pulling 瞬态再进来,
    /// 一旦"取消后跳过剩余输入",这些行永远等不到终态回写,整个工作区 UI 被
    /// isBusy 锁死(分支面板全灰)。曾因给这里加"取消快速退出"优化而翻车。
    func test_runLimitedTasksReturnsAllResultsWhenParentCancelledMidFlight() async {
        let inputs = Array(0..<20)
        let task = Task {
            await ConcurrencyUtilities.runLimitedTasks(
                inputs,
                maxConcurrentTasks: 2
            ) { value in
                // 子任务对取消的自我处理:睡不睡成都照常产出结果。
                try? await Task.sleep(nanoseconds: 5_000_000)
                return value * 2
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let results = await task.value
        XCTAssertEqual(results.count, inputs.count, "取消不得吞掉未开始输入的返回值")
        XCTAssertEqual(results, inputs.map { $0 * 2 })
    }

    // MARK: - canonical key 归一化 / 公平性 / in-flight 快照

    func test_trailingSlashVariantSharesLockWithPlainPath() async throws {
        let lock = RepositoryOperationLock()
        try await lock.acquire(path: "/tmp/ccspace-lock-key/x")

        let waiterFinished = WaitFlag()
        let waiter = Task {
            try? await lock.acquire(path: "/tmp/ccspace-lock-key/x/")
            await waiterFinished.mark()
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let finishedEarly = await waiterFinished.isSet()
        XCTAssertFalse(finishedEarly, "trailing slash 只是同一目录的另一种写法,不得绕过互斥")

        waiter.cancel()
        await waiter.value
        await lock.release(path: "/tmp/ccspace-lock-key/x")
    }

    func test_caseVariantSharesLockWithPlainPath() async throws {
        let lock = RepositoryOperationLock()
        try await lock.acquire(path: "/tmp/ccspace-case-key/repo")

        let waiterFinished = WaitFlag()
        let waiter = Task {
            try? await lock.acquire(path: "/TMP/CcSpace-Case-Key/Repo")
            await waiterFinished.mark()
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let finishedEarly = await waiterFinished.isSet()
        XCTAssertFalse(finishedEarly, "macOS 默认卷大小写不敏感,大小写变体必须是同一把锁")

        waiter.cancel()
        await waiter.value
        await lock.release(path: "/TMP/CcSpace-Case-Key/Repo")
    }

    func test_waiterIsNotStarvedByNewlyArrivingAcquirer() async throws {
        let lock = RepositoryOperationLock()
        try await lock.acquire(path: "/tmp/ccspace-fairness")

        // B 先进入等待队列(拿到后立即释放,让 C 也能收敛)。
        let bEntered = WaitFlag()
        let b = Task {
            try await lock.acquire(path: "/tmp/ccspace-fairness")
            await bEntered.mark()
            await lock.release(path: "/tmp/ccspace-fairness")
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // C 后到:快速路径必须因 B 在排队而让 C 也排队(否则会无限插队饿死长持有者)。
        let cEntered = WaitFlag()
        let c = Task {
            try await lock.acquire(path: "/tmp/ccspace-fairness")
            await cEntered.mark()
            await lock.release(path: "/tmp/ccspace-fairness")
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let cGotInEarly = await cEntered.isSet()
        XCTAssertFalse(cGotInEarly, "存在等待者时新到达者不得插队获取锁")

        await lock.release(path: "/tmp/ccspace-fairness")
        try await b.value
        try await c.value
        let keysAfter = await lock.inFlightPathKeys()
        XCTAssertFalse(
            keysAfter.contains(LocalPathSafety.canonicalLockKey(for: "/tmp/ccspace-fairness")),
            "全部释放后不应残留持锁记录"
        )
    }

    func test_inFlightPathKeysIncludesActiveAndWaitingNormalizedKeys() async throws {
        let lock = RepositoryOperationLock()
        let plain = "/tmp/ccspace-inflight/alpha"
        let variant = "/tmp/ccspace-inflight/alpha/"
        try await lock.acquire(path: plain)

        let waiter = Task {
            try? await lock.acquire(path: "/tmp/ccspace-inflight/beta")
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let keys = await lock.inFlightPathKeys()
        XCTAssertTrue(
            keys.contains(LocalPathSafety.canonicalLockKey(for: variant)),
            "快照 key 必须与磁盘刷新侧用同一套 canonical 形式,否则豁免匹配不上"
        )
        XCTAssertTrue(keys.contains(LocalPathSafety.canonicalLockKey(for: "/tmp/ccspace-inflight/beta")))

        waiter.cancel()
        await waiter.value
        await lock.release(path: plain)
        let keysAfterRelease = await lock.inFlightPathKeys()
        XCTAssertFalse(keysAfterRelease.contains(LocalPathSafety.canonicalLockKey(for: plain)))
    }

    // MARK: - canonicalLockOrder(多路径唯一获取顺序)

    /// `canonicalLockOrder` 是多路径加锁的唯一顺序入口(`withLockPaths` 直接调用它)。
    /// 归一(大小写/尾斜杠/symlink 别名)去重 + 按 canonical key 排序,
    /// 且与输入顺序无关——两处一旦漂移,两个持有者顺序相反就构成环形死锁。
    func test_canonicalLockOrderNormalizesDeduplicatesAndSortsStably() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccspace-lock-order-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)

        // 同一物理目录的四种写法 + 另一条真实路径 + 重复项。
        let paths = [
            repo.path + "/",      // trailing slash
            root.appendingPathComponent("REPO").path, // 大小写变体
            alias.path,           // symlink 别名
            root.path,            // 另一条路径(根)
            repo.path,            // 与首项重复
        ]

        let order = RepositoryOperationLock.canonicalLockOrder(paths)
        let repoKey = LocalPathSafety.canonicalLockKey(for: repo.path)
        let rootKey = LocalPathSafety.canonicalLockKey(for: root.path)

        // 归一去重:四种写法折叠为 repoKey 一把锁,加上 rootKey 共两把。
        XCTAssertEqual(order.count, 2, "大小写/尾斜杠/symlink 变体必须折叠去重,实际:\(order)")
        XCTAssertEqual(Set(order), Set([repoKey, rootKey]))
        // 结果按 canonical key 字典序排序。
        XCTAssertEqual(order, order.sorted())
        // 与输入顺序无关:乱序、子集重复输入必须得到同一条顺序
        // (withLockPaths 拿到的就是这个顺序,防止两处再次漂移)。
        XCTAssertEqual(order, RepositoryOperationLock.canonicalLockOrder(paths.reversed()))
        XCTAssertEqual(
            order,
            RepositoryOperationLock.canonicalLockOrder([root.path, alias.path, repo.path, root.path])
        )
    }

    /// 行为锁:`withLockPaths` 的实际获取顺序必须等于 `canonicalLockOrder`。
    /// 用大小写翻转字典序的路径对(Beta < alpha 按原始字符串、
    /// alpha < beta 按 canonical key):持住 canonical 排序靠后的那条,
    /// 批量获取必须先拿到靠前的那条再阻塞——若按原始字符串排序,
    /// 它会先阻塞在靠后的路径上,靠前的 key 永远不出现在持锁快照里。
    func test_withLockPathsAcquiresMembersInCanonicalLockOrder() async throws {
        let lock = RepositoryOperationLock()
        let alpha = "/tmp/ccspace-lock-order-acquire/alpha"
        let beta = "/tmp/ccspace-lock-order-acquire/Beta"
        let order = RepositoryOperationLock.canonicalLockOrder([alpha, beta])
        XCTAssertEqual(order.count, 2)
        // 前提自检:canonical 顺序把 alpha 排在前,而原始字符串排序恰好相反
        // ("B" < "a"),否则本用例区分不出"按 canonical 排序"与"按原始路径排序"。
        XCTAssertTrue(
            order.first?.hasSuffix("/alpha") == true,
            "canonical 顺序应把 alpha 排在 Beta 前,实际:\(order)"
        )
        XCTAssertTrue(
            [alpha, beta].sorted().first?.hasSuffix("/Beta") == true,
            "本用例要求原始字符串排序与 canonical 排序方向相反"
        )

        // 持住 canonical 排序靠后的路径(order[1])。
        try await lock.acquire(path: order[1])

        let batchFinished = WaitFlag()
        let batch = Task {
            // 故意打乱输入顺序:内部必须重排成 canonical 顺序获取。
            try await lock.withLockPaths([beta, alpha]) {
                await batchFinished.mark()
            }
        }

        var acquiredLeadingKey = false
        var keysSnapshot: Set<String> = []
        for _ in 0..<50 {
            keysSnapshot = await lock.inFlightPathKeys()
            if keysSnapshot.contains(order[0]) {
                acquiredLeadingKey = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            acquiredLeadingKey,
            "批量加锁必须先取得 canonical 排序靠前的路径(顺序与 canonicalLockOrder 一致),实际持锁:\(keysSnapshot)"
        )
        let finishedEarly = await batchFinished.isSet()
        XCTAssertFalse(
            finishedEarly,
            "靠后的路径仍被持住时批量操作不得完成"
        )

        await lock.release(path: order[1])
        try await batch.value
        let finishedAfterRelease = await batchFinished.isSet()
        XCTAssertTrue(finishedAfterRelease, "全部释放后批量操作应完成")
    }
}

/// @unchecked Sendable 的获取标记盒,避免测试闭包捕获 XCTestCase self。
private final class LockAcquisitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false

    func markAcquired() {
        lock.lock()
        acquired = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return acquired
    }
}

/// 批量锁测试用的完成标记。
private actor WaitFlag {
    private var set = false

    func mark() { set = true }

    func isSet() -> Bool { set }
}
