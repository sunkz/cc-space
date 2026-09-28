import XCTest
@testable import CCSpace

final class WorkplaceBranchSnapshotMergeTests: XCTestCase {
    private let workplaceID = UUID()

    func test_fetchFailureKeepsPreviousSnapshotForKey() {
        let key = makeKey("repo")
        let previous = makeSnapshot(currentBranch: "main", branches: ["main", "dev"])

        let merged = WorkplaceBranchSnapshotMerge.merge(
            attemptedKeys: [key],
            fresh: [:],
            previous: [key: previous]
        )

        XCTAssertEqual(merged[key]?.currentBranch, "main")
        XCTAssertEqual(merged[key]?.branches, ["main", "dev"])
    }

    func test_freshSnapshotOverridesPrevious() {
        let key = makeKey("repo")
        let previous = makeSnapshot(currentBranch: "main", branches: ["main"])
        let fresh = makeSnapshot(currentBranch: "dev", branches: ["dev"])

        let merged = WorkplaceBranchSnapshotMerge.merge(
            attemptedKeys: [key],
            fresh: [key: fresh],
            previous: [key: previous]
        )

        XCTAssertEqual(merged, [key: fresh])
    }

    func test_keyAbsentFromAttemptedSetIsDroppedEvenWithPreviousSnapshot() {
        let kept = makeKey("kept")
        let removed = makeKey("removed")
        let fresh = makeSnapshot(currentBranch: "main", branches: ["main"])

        let merged = WorkplaceBranchSnapshotMerge.merge(
            attemptedKeys: [kept],
            fresh: [kept: fresh],
            previous: [removed: fresh]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[kept], fresh)
        XCTAssertNil(merged[removed])
    }

    func test_keyWithoutAnySnapshotProducesNoEntry() {
        let key = makeKey("repo")

        let merged = WorkplaceBranchSnapshotMerge.merge(
            attemptedKeys: [key],
            fresh: [:],
            previous: [:]
        )

        XCTAssertTrue(merged.isEmpty)
    }

    private func makeKey(_ seed: String) -> RepositoryBranchCacheKey {
        RepositoryBranchCacheKey(
            workplaceID: workplaceID,
            repositoryID: uuid(from: seed)
        )
    }

    private func uuid(from seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in seed.utf8.enumerated() where index < 16 {
            bytes[index] = byte
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func makeSnapshot(currentBranch: String, branches: [String]) -> RepositoryBranchSnapshot {
        RepositoryBranchSnapshot(currentBranch: currentBranch, branches: branches, status: nil)
    }
}
