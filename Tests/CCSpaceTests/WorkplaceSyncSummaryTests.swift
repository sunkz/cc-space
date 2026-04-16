import XCTest
@testable import CCSpace

final class WorkplaceSyncSummaryTests: XCTestCase {
    func test_countsStatusesForSelectedWorkplace() {
        let workplaceID = UUID()
        let states = [
            RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: UUID(),
                status: .success,
                localPath: "/tmp/a",
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: UUID(),
                status: .failed,
                localPath: "/tmp/b",
                lastError: "clone failed",
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: workplaceID,
                repositoryID: UUID(),
                status: .cloning,
                localPath: "/tmp/c",
                lastError: nil,
                lastSyncedAt: nil
            ),
            RepositorySyncState(
                workplaceID: UUID(),
                repositoryID: UUID(),
                status: .success,
                localPath: "/tmp/d",
                lastError: nil,
                lastSyncedAt: nil
            ),
        ]

        let summary = WorkplaceSyncSummary(workplaceID: workplaceID, syncStates: states)

        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.activeCount, 1)
    }
}
