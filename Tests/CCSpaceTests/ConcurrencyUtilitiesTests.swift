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
