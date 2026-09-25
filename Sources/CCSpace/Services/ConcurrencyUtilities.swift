import Foundation

enum ConcurrencyUtilities {
    static func runLimitedTasks<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard inputs.isEmpty == false else { return [] }

        return await withTaskGroup(of: (Int, Output).self, returning: [Output].self) { group in
            let initialTaskCount = min(maxConcurrentTasks, inputs.count)
            var nextInputIndex = 0
            var results = Array<Output?>(repeating: nil, count: inputs.count)

            func addTask(for index: Int) {
                let input = inputs[index]
                group.addTask {
                    (index, await operation(input))
                }
            }

            for _ in 0..<initialTaskCount {
                addTask(for: nextInputIndex)
                nextInputIndex += 1
            }

            while let (index, result) = await group.next() {
                results[index] = result
                guard nextInputIndex < inputs.count else { continue }
                addTask(for: nextInputIndex)
                nextInputIndex += 1
            }

            return results.compactMap { $0 }
        }
    }
}

actor RepositoryOperationLock {
    static let shared = RepositoryOperationLock()

    private struct Waiter {
        let path: String
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activePaths = Set<String>()
    private var waiters: [Waiter] = []

    /// 获取指定路径的操作锁;等待期间任务被取消时抛 `CancellationError`,
    /// 不再无限挂起。成功返回即持有锁,调用方负责 `release`。
    func acquire(path: String) async throws {
        try Task.checkCancellation()
        if activePaths.contains(path) == false {
            activePaths.insert(path)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(path: path, id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }

        // 被 release() 唤醒即视为已持锁;此刻任务若已取消,立即让位给下一个等待者。
        if Task.isCancelled {
            release(path: path)
            throw CancellationError()
        }
    }

    func release(path: String) {
        activePaths.remove(path)
        if let index = waiters.firstIndex(where: { $0.path == path }) {
            let waiter = waiters.remove(at: index)
            activePaths.insert(path)
            waiter.continuation.resume()
        }
    }

    func withLock<T: Sendable>(path: String, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(path: path)
        do {
            let result = try await operation()
            release(path: path)
            return result
        } catch {
            // operation 抛错也必须释放,否则该路径的锁被永久占用,等待者全部挂起。
            release(path: path)
            throw error
        }
    }

    /// 同时持有多条路径的锁执行操作。锁 key 是精确匹配,父目录锁罩不住子目录写操作,
    /// 因此对"目录树级"操作(整棵工作区删除、批量克隆)必须把树内每条仓库路径与目录
    /// 自身一起加锁,才能与 pull/push/切分支等 per-path 写路径真正互斥。
    /// 路径去重后按字典序逐个获取,所有持有者取得顺序一致,不会死锁;
    /// 获取过程中任一路径被取消或失败,已持有的锁全部回滚释放。
    func withLockPaths<T: Sendable>(
        _ paths: [String],
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let sorted = Set(paths).sorted()
        var acquired: [String] = []
        do {
            for path in sorted {
                try await acquire(path: path)
                acquired.append(path)
            }
        } catch {
            for path in acquired.reversed() {
                release(path: path)
            }
            throw error
        }
        do {
            let result = try await operation()
            for path in acquired.reversed() {
                release(path: path)
            }
            return result
        } catch {
            for path in acquired.reversed() {
                release(path: path)
            }
            throw error
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
