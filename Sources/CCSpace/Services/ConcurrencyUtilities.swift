import Foundation
import os

private let repositoryOperationLockLog = Logger(
    subsystem: "com.ccspace.app",
    category: "RepositoryOperationLock"
)

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
                // 注意:这里**不能**加"父任务已取消就停止入队"的优化——
                // 调用方(如 pullRepositories)会先把全部行预标成 .pulling 瞬态再进来,
                // 一旦取消时跳过剩余输入,这些行拿不到终态结果、永远卡在"进行中",
                // 把整个工作区 UI 锁死(分支面板全灰不可点)。
                // 子任务自身对取消有快速失败路径,照常入队即可。
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
        /// 已规范化的锁 key(`LocalPathSafety.canonicalLockKey`),不是原始路径。
        let key: String
        /// 原始路径:取消出队时按它回收 raw→key 映射记录。
        let rawPath: String
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeKeys: Set<String> = []
    private var waiters: [Waiter] = []
    /// 原始路径 → acquire 时记录的规范化 key(数组作多重集:同一原始路径可被
    /// 并发持有多次,磁盘形态变化还可能让两次推导得到不同 key)。
    ///
    /// release 据此取 key 而**不重新推导**:canonicalLockKey 依赖磁盘状态
    /// (symlink 解析、缺失尾部重建),acquire 与 release 之间路径的磁盘形态若发生
    /// 变化,重推导会得到不同的 key,activeKeys.remove 落空,锁被永久泄漏——
    /// 该路径后续所有 acquire 全部挂起,等于这个仓库的所有操作从此锁死。
    private var keysByRawPath: [String: [String]] = [:]

    /// 当前正被持有或有人排队等待的路径 key 快照。
    /// 磁盘刷新据此豁免"有长操作进行中"的路径:克隆/改名/删除进行到一半时,
    /// 目录可能暂时不存在,若不豁免会把"记录在、目录未落位"的行误判为 missing 而删除记录。
    func inFlightPathKeys() -> Set<String> {
        var snapshot = activeKeys
        for waiter in waiters {
            snapshot.insert(waiter.key)
        }
        return snapshot
    }

    /// 获取指定路径的操作锁;等待期间任务被取消时抛 `CancellationError`,
    /// 不再无限挂起。成功返回即持有锁,调用方负责 `release`。
    func acquire(path: String) async throws {
        let key = LocalPathSafety.canonicalLockKey(for: path)
        try Task.checkCancellation()
        // 快速路径同样检查排队者:否则持续有新的 per-path pull 到达时,
        // 等整树多路径锁的长持有者(deleteWorkplace 等)会被不断插队饿死。
        if activeKeys.contains(key) == false,
           waiters.contains(where: { $0.key == key }) == false {
            activeKeys.insert(key)
            recordKey(rawPath: path, key: key)
            return
        }

        let waiterID = UUID()
        // 入队前先记映射、取消出队时由 cancelWaiter 回收:持有/等待/取消三条路径
        // 的映射计数与实际持有严格一致。唤醒后再补记会有 actor 重入窗口
        //(release 重插 key 与唤醒任务的补记之间,其他 actor 消息可插队)。
        recordKey(rawPath: path, key: key)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    // 未真正入队即取消:回收刚记的映射,避免计数虚增。
                    unrecordKey(rawPath: path, key: key)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(key: key, rawPath: path, id: waiterID, continuation: continuation))
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
        // 以 acquire 时记录的映射为准,绝不重新推导(见 keysByRawPath 注释)。
        // 查不到记录说明重复释放或从未获取:按错误处理但不摘除任何在案 key,
        // 避免误删其他持有者的锁。
        guard var recordedKeys = keysByRawPath[path], recordedKeys.isEmpty == false else {
            repositoryOperationLockLog.error(
                "释放仓库操作锁失败：路径未在 acquire 时记录（重复释放或从未获取）：\(path, privacy: .public)"
            )
            return
        }
        let key = recordedKeys.removeFirst()
        if recordedKeys.isEmpty {
            keysByRawPath.removeValue(forKey: path)
        } else {
            keysByRawPath[path] = recordedKeys
        }
        activeKeys.remove(key)
        if let index = waiters.firstIndex(where: { $0.key == key }) {
            let waiter = waiters.remove(at: index)
            activeKeys.insert(key)
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
        // 按规范化 key 去重:同一物理目录的两种写法(大小写/trailing slash)
        // 归一后是同一把锁,按原始字符串去重会对同一 key 二次 acquire 自陷等待。
        let sorted = Set(paths.map(LocalPathSafety.canonicalLockKey(for:))).sorted()
        var acquired: [String] = []
        do {
            // sorted 已是 canonical key;acquire 内部归一化幂等,直接透传。
            for key in sorted {
                try await acquire(path: key)
                acquired.append(key)
            }
        } catch {
            for key in acquired.reversed() {
                release(path: key)
            }
            throw error
        }
        do {
            let result = try await operation()
            for key in acquired.reversed() {
                release(path: key)
            }
            return result
        } catch {
            for key in acquired.reversed() {
                release(path: key)
            }
            throw error
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        // 取消出队即回收该次 acquire 的映射记录,保持映射计数与实际持有一致。
        unrecordKey(rawPath: waiter.rawPath, key: waiter.key)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func recordKey(rawPath: String, key: String) {
        keysByRawPath[rawPath, default: []].append(key)
    }

    private func unrecordKey(rawPath: String, key: String) {
        guard var keys = keysByRawPath[rawPath],
              let index = keys.firstIndex(of: key) else {
            return
        }
        keys.remove(at: index)
        if keys.isEmpty {
            keysByRawPath.removeValue(forKey: rawPath)
        } else {
            keysByRawPath[rawPath] = keys
        }
    }
}
