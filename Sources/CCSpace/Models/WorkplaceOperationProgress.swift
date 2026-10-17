import Foundation
import os

private let progressTrackerLog = Logger(
    subsystem: "com.ccspace.app",
    category: "WorkplaceOperationProgress"
)

typealias WorkplaceOperationProgressHandler = @MainActor @Sendable (WorkplaceOperationProgress) -> Void

enum WorkplaceOperationProgressStep: Equatable, Sendable {
    case cloningRepositories
    case removingRepositories
    case switchingBranches(branch: String)
}

struct WorkplaceOperationProgress: Sendable {
    let step: WorkplaceOperationProgressStep
    let completedCount: Int
    let totalCount: Int
    let activeRepositoryNames: [String]
    let startedAt: Date

    init(
        step: WorkplaceOperationProgressStep,
        completedCount: Int,
        totalCount: Int,
        activeRepositoryNames: [String],
        startedAt: Date = Date()
    ) {
        self.step = step
        self.totalCount = max(0, totalCount)
        self.completedCount = max(0, min(completedCount, self.totalCount))
        self.activeRepositoryNames = activeRepositoryNames.compactMap { name in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? nil : trimmedName
        }
        self.startedAt = startedAt
    }
}

extension WorkplaceOperationProgress: Equatable {
    /// `startedAt` 刻意不参与相等判定:它每次 emit 都在变,参与比较会让同一步骤被反复判为
    /// "进度变了"(UI 抖动 + 测试不可重现)。
    static func == (lhs: WorkplaceOperationProgress, rhs: WorkplaceOperationProgress) -> Bool {
        lhs.step == rhs.step
            && lhs.completedCount == rhs.completedCount
            && lhs.totalCount == rhs.totalCount
            && lhs.activeRepositoryNames == rhs.activeRepositoryNames
    }
}

actor WorkplaceOperationProgressTracker {
    private let step: WorkplaceOperationProgressStep
    private let totalCount: Int
    private let progressHandler: WorkplaceOperationProgressHandler?
    private let startedAt = Date()
    private var completedCount = 0
    private var activeRepositoryNames: [String] = []

    init(
        step: WorkplaceOperationProgressStep,
        totalCount: Int,
        progressHandler: WorkplaceOperationProgressHandler?
    ) {
        self.step = step
        self.totalCount = totalCount
        self.progressHandler = progressHandler
    }

    func didStart(repositoryName: String) async {
        guard totalCount > 0 else { return }
        activeRepositoryNames.append(repositoryName)
        await emitProgress()
    }

    func didFinish(repositoryName: String) async {
        guard totalCount > 0 else { return }
        // 只有真正 start 过的名称才计数:未 start 或重复 finish 的孤儿调用会提前把进度推到 100%,掩盖在跑的操作。
        guard let index = activeRepositoryNames.firstIndex(of: repositoryName) else {
            progressTrackerLog.notice(
                "event=progress_did_finish_orphan repository_name=\(repositoryName, privacy: .public)"
            )
            return
        }
        activeRepositoryNames.remove(at: index)
        completedCount = min(totalCount, completedCount + 1)
        await emitProgress()
    }

    private func emitProgress() async {
        guard let progressHandler else { return }
        await progressHandler(
            WorkplaceOperationProgress(
                step: step,
                completedCount: completedCount,
                totalCount: totalCount,
                activeRepositoryNames: activeRepositoryNames,
                startedAt: startedAt
            )
        )
    }
}
