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

struct WorkplaceOperationProgress: Equatable, Sendable {
    let step: WorkplaceOperationProgressStep
    let completedCount: Int
    let totalCount: Int
    let activeRepositoryNames: [String]

    init(
        step: WorkplaceOperationProgressStep,
        completedCount: Int,
        totalCount: Int,
        activeRepositoryNames: [String]
    ) {
        self.step = step
        self.totalCount = max(0, totalCount)
        self.completedCount = max(0, min(completedCount, self.totalCount))
        self.activeRepositoryNames = activeRepositoryNames.compactMap { name in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? nil : trimmedName
        }
    }
}

actor WorkplaceOperationProgressTracker {
    private let step: WorkplaceOperationProgressStep
    private let totalCount: Int
    private let progressHandler: WorkplaceOperationProgressHandler?
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
        // 只有真正从进行中列表移除(即该名称确实被 start 过)才计数:
        // 未 start 就 finish、或对同一名称重复 finish 的孤儿调用不能递增
        // completedCount,否则进度会被提前推到 100%,掩盖还在进行的操作。
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
                activeRepositoryNames: activeRepositoryNames
            )
        )
    }
}
