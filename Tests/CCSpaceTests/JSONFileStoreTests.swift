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

    func test_rollbackRestoresOriginalOnPartialWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore(rootDirectory: root)

        let original = [
            RepositoryConfig(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                gitURL: "git@github.com:team/web.git",
                repoName: "web",
                createdAt: .now,
                updatedAt: .now
            )
        ]
        try store.save(original, as: "repositories.json")

        let doc1 = try store.document(for: original, as: "repositories.json")
        let badDoc = JSONFileStoreDocument(fileName: "bad/\0/path.json", data: Data([0xFF]))

        XCTAssertThrowsError(try store.save([doc1, badDoc]))

        let restored: [RepositoryConfig] = try store.load(
            [RepositoryConfig].self,
            from: "repositories.json"
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.repoName, "web")
    }

    func test_atomicMultiDocumentWriteIsAllOrNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore(rootDirectory: root)

        let items1 = [
            RepositoryConfig(
                id: UUID(),
                gitURL: "git@github.com:team/a.git",
                repoName: "a",
                createdAt: .now,
                updatedAt: .now
            )
        ]
        let items2 = AppSettings(workplaceRootPath: "/original")

        try store.save(items1, as: "repos.json")
        try store.save(items2, as: "settings.json")

        let doc1 = try store.document(for: items1, as: "repos.json")
        let doc2 = try store.document(for: AppSettings(workplaceRootPath: "/updated"), as: "settings.json")
        let badDoc = JSONFileStoreDocument(fileName: "sub/\0/bad.json", data: Data())

        XCTAssertThrowsError(try store.save([doc1, doc2, badDoc]))

        let loadedSettings: AppSettings = try store.load(AppSettings.self, from: "settings.json")
        XCTAssertEqual(loadedSettings.workplaceRootPath, "/original")
    }
}
