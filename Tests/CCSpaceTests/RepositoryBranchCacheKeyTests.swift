import XCTest
@testable import CCSpace

final class RepositoryBranchCacheKeyTests: XCTestCase {
    func test_keysDifferForSameRepositoryAcrossWorkplaces() {
        let repositoryID = UUID(uuidString: "FA6F8C19-0AF1-4876-AD24-A28FEB258AD1")!
        let helloWorkplaceID = UUID(uuidString: "F98B87A5-FF33-4BBD-B7BF-EDDB0D277C4F")!
        let hiWorkplaceID = UUID(uuidString: "2E1F0D28-BB41-49B5-904F-0A002D6219A5")!

        let helloKey = RepositoryBranchCacheKey(
            workplaceID: helloWorkplaceID,
            repositoryID: repositoryID
        )
        let hiKey = RepositoryBranchCacheKey(
            workplaceID: hiWorkplaceID,
            repositoryID: repositoryID
        )

        XCTAssertNotEqual(helloKey, hiKey)

        let branches: [RepositoryBranchCacheKey: String] = [
            helloKey: "main",
            hiKey: "01"
        ]

        XCTAssertEqual(branches[helloKey], "main")
        XCTAssertEqual(branches[hiKey], "01")
    }
}
