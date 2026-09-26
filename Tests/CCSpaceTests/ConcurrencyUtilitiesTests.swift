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
