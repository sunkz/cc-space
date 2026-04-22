import Foundation

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
        self.completedCount = max(0, min(completedCount, totalCount))
        self.totalCount = max(0, totalCount)
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
        if let index = activeRepositoryNames.firstIndex(of: repositoryName) {
            activeRepositoryNames.remove(at: index)
        }
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
