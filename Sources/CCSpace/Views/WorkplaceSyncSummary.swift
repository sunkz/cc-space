import Foundation

struct WorkplaceSyncSummary {
    let totalCount: Int
    let successCount: Int
    let failedCount: Int
    let activeCount: Int

    var idleCount: Int {
        max(totalCount - successCount - failedCount - activeCount, 0)
    }

    init(workplaceID: UUID, syncStates: [RepositorySyncState]) {
        var total = 0
        var success = 0
        var failed = 0
        var active = 0
        for state in syncStates where state.workplaceID == workplaceID {
            total += 1
            switch state.status {
            case .success: success += 1
            case .failed: failed += 1
            case .cloning, .pulling, .removing: active += 1
            case .idle: break
            }
        }
        totalCount = total
        successCount = success
        failedCount = failed
        activeCount = active
    }
}
