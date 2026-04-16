import XCTest
@testable import CCSpace

final class JSONFileStoreTests: XCTestCase {
    func test_roundTripsRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore(rootDirectory: root)
        let items = [
            RepositoryConfig(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                gitURL: "git@github.com:team/api.git",
                repoName: "api",
                createdAt: .now,
                updatedAt: .now
            )
        ]

        try store.save(items, as: "repositories.json")
        let loaded: [RepositoryConfig] = try store.load([RepositoryConfig].self, from: "repositories.json")

        XCTAssertEqual(loaded.map(\.repoName), ["api"])
    }

    func test_loadIfPresentReturnsDefaultWhenFileMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore(rootDirectory: root)
        let defaultValue = AppSettings(workplaceRootPath: "/tmp/workplaces")

        let loaded = try store.loadIfPresent(
            AppSettings.self,
            from: "settings.json",
            default: defaultValue
        )

        XCTAssertEqual(loaded, defaultValue)
    }
}
