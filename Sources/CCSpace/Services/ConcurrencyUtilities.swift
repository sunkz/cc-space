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

    static func runLimitedTasksWithCancellation<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async -> Output?
    ) async -> [Output] {
        guard inputs.isEmpty == false else { return [] }

        return await withTaskGroup(of: Output?.self, returning: [Output].self) { group in
            let initialTaskCount = min(maxConcurrentTasks, inputs.count)
            var nextInputIndex = 0

            for _ in 0..<initialTaskCount {
                let input = inputs[nextInputIndex]
                nextInputIndex += 1
                group.addTask {
                    await operation(input)
                }
            }

            var results: [Output] = []
            while let result = await group.next() {
                if let result { results.append(result) }
                guard Task.isCancelled == false else {
                    group.cancelAll()
                    continue
                }
                guard nextInputIndex < inputs.count else { continue }
                let input = inputs[nextInputIndex]
                nextInputIndex += 1
                group.addTask {
                    await operation(input)
                }
            }
            return results
        }
    }
}

actor RepositoryOperationLock {
    static let shared = RepositoryOperationLock()

    private var activePaths = Set<String>()
    private var waiters: [(path: String, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(path: String) async {
        if activePaths.contains(path) {
            await withCheckedContinuation { continuation in
                waiters.append((path: path, continuation: continuation))
            }
        }
        activePaths.insert(path)
    }

    func release(path: String) {
        activePaths.remove(path)
        if let index = waiters.firstIndex(where: { $0.path == path }) {
            let waiter = waiters.remove(at: index)
            activePaths.insert(path)
            waiter.continuation.resume()
        }
    }

    func withLock<T: Sendable>(path: String, operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(path: path)
        let result = try await operation()
        release(path: path)
        return result
    }
}
