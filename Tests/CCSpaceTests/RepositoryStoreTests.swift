import XCTest
@testable import CCSpace

@MainActor
final class RepositoryStoreTests: XCTestCase {
    func test_addRepositoryRejectsDuplicateURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try await store.addRepository(gitURL: "git@github.com:org/api.git")

        do {
            try await store.addRepository(gitURL: "git@github.com:org/api.git")
            XCTFail("Expected duplicate URL error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "仓库地址已存在")
        }
    }

    func test_addRepositoryRejectsDuplicateRepoNameFromDifferentURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try await store.addRepository(gitURL: "git@github.com:team-a/api.git")

        do {
            try await store.addRepository(gitURL: "https://github.com/team-b/api.git")
            XCTFail("Expected duplicate repo name error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "仓库名称已存在")
        }
    }

    func test_addRepositoryRejectsInvalidRepoNameForLocalPath() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertThrowsError(
            try store.addRepository(gitURL: "git@github.com:org/..")
        ) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .invalidRepoName)
        }
    }

    func test_removeRepositoryDeletesAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)

        try await store.addRepository(gitURL: "git@github.com:org/api.git")
        try await store.addRepository(gitURL: "git@github.com:org/web.git")
        XCTAssertEqual(store.repositories.count, 2)

        let idToRemove = store.repositories[0].id
        try store.removeRepository(id: idToRemove)
        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertFalse(store.repositories.contains(where: { $0.id == idToRemove }))

        // Verify persistence
        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.count, 1)
    }

    func test_updateRepositoryChangesURLWithoutChangingRepoName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)

        try await store.addRepository(gitURL: "git@github.com:org/api.git")
        let repoID = store.repositories.first!.id

        try store.updateRepository(id: repoID, gitURL: "git@gitlab.example.com:team/api.git")

        XCTAssertEqual(store.repositories.first?.gitURL, "git@gitlab.example.com:team/api.git")
        XCTAssertEqual(store.repositories.first?.repoName, "api")

        // Verify persistence
        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.first?.gitURL, "git@gitlab.example.com:team/api.git")
    }

    func test_addAndUpdateRepositoryTrimWhitespace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try await store.addRepository(gitURL: " git@github.com:org/api.git ")
        let repoID = try XCTUnwrap(store.repositories.first?.id)
        XCTAssertEqual(store.repositories.first?.gitURL, "git@github.com:org/api.git")

        try store.updateRepository(id: repoID, gitURL: " git@gitlab.example.com:team/api.git ")
        XCTAssertEqual(store.repositories.first?.gitURL, "git@gitlab.example.com:team/api.git")
    }

    func test_updateRepositoryRejectsDuplicateURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try await store.addRepository(gitURL: "git@github.com:org/api.git")
        try await store.addRepository(gitURL: "git@github.com:org/web.git")
        let webID = store.repositories.first { $0.repoName == "web" }!.id

        XCTAssertThrowsError(
            try store.updateRepository(id: webID, gitURL: "git@github.com:org/api.git")
        ) { error in
            XCTAssertEqual(error.localizedDescription, "仓库地址已存在")
        }
    }

    func test_updateRepositoryRejectsRepoNameChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try await store.addRepository(gitURL: "git@github.com:org/api.git")
        let repoID = store.repositories.first { $0.repoName == "api" }!.id

        XCTAssertThrowsError(
            try store.updateRepository(id: repoID, gitURL: "git@github.com:org/backend.git")
        ) { error in
            XCTAssertEqual(error.localizedDescription, "暂不支持通过编辑修改仓库名称，请新增仓库后替换")
        }
    }

    func test_deduplicatePersistedRepositoriesDoesNotAutoImportRepositoriesFromDisk() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = RepositoryStore(fileStore: fileStore)

        let workplaceA = rootDirectory.appendingPathComponent("hello")
        let workplaceB = rootDirectory.appendingPathComponent("hi")
        let repoA = workplaceA.appendingPathComponent("blog")
        let repoB = workplaceB.appendingPathComponent("blog-copy")

        try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB.appendingPathComponent(".git"), withIntermediateDirectories: true)

        _ = rootDirectory
        store.deduplicatePersistedRepositories()

        XCTAssertTrue(store.repositories.isEmpty)
    }
}
