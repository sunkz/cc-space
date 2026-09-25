import XCTest
@testable import CCSpace

final class WorkplaceRepositorySortingTests: XCTestCase {
    func test_sortsByNameAscendingWhenNothingPinned() {
        let alpha = makeSyncState(localPath: "/tmp/alpha")
        let bravo = makeSyncState(localPath: "/tmp/bravo")
        let charlie = makeSyncState(localPath: "/tmp/charlie")

        let result = WorkplaceRepositorySorting.sortRepositorySyncStates(
            [charlie, alpha, bravo],
            pinnedRepositoryIDs: []
        )

        XCTAssertEqual(result.map(\.localPath), [
            "/tmp/alpha", "/tmp/bravo", "/tmp/charlie"
        ])
    }

    func test_pinnedRepositoriesAppearFirstAndSortedWithinGroup() {
        let alpha = makeSyncState(localPath: "/tmp/alpha")
        let bravo = makeSyncState(localPath: "/tmp/bravo")
        let charlie = makeSyncState(localPath: "/tmp/charlie")

        let result = WorkplaceRepositorySorting.sortRepositorySyncStates(
            [alpha, bravo, charlie],
            pinnedRepositoryIDs: [charlie.repositoryID, alpha.repositoryID]
        )

        XCTAssertEqual(result.map(\.localPath), [
            "/tmp/alpha", "/tmp/charlie", "/tmp/bravo"
        ])
    }

    func test_unknownPinnedIDsAreIgnored() {
        let alpha = makeSyncState(localPath: "/tmp/alpha")
        let bravo = makeSyncState(localPath: "/tmp/bravo")
        let strangerID = UUID()

        let result = WorkplaceRepositorySorting.sortRepositorySyncStates(
            [bravo, alpha],
            pinnedRepositoryIDs: [strangerID]
        )

        XCTAssertEqual(result.map(\.localPath), ["/tmp/alpha", "/tmp/bravo"])
    }

    private func makeSyncState(localPath: String) -> RepositorySyncState {
        RepositorySyncState(
            workplaceID: UUID(),
            repositoryID: UUID(),
            status: .success,
            localPath: localPath,
            lastError: nil,
            lastSyncedAt: nil
        )
    }
}
