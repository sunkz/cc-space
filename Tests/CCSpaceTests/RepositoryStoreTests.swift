import XCTest
@testable import CCSpace

@MainActor
final class RepositoryStoreTests: XCTestCase {
    func test_addRepositoryRejectsDuplicateURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: "git@github.com:org/api.git")

        do {
            try store.addRepository(gitURL: "git@github.com:org/api.git")
            XCTFail("Expected duplicate URL error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "仓库地址已存在")
        }
    }

    func test_addRepositoryRejectsDuplicateRepoNameFromDifferentURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: "git@github.com:team-a/api.git")

        do {
            try store.addRepository(gitURL: "https://github.com/team-b/api.git")
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

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.addRepository(gitURL: "git@github.com:org/web.git")
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

        try store.addRepository(gitURL: "git@github.com:org/api.git")
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

        try store.addRepository(gitURL: " git@github.com:org/api.git ")
        let repoID = try XCTUnwrap(store.repositories.first?.id)
        XCTAssertEqual(store.repositories.first?.gitURL, "git@github.com:org/api.git")

        try store.updateRepository(id: repoID, gitURL: " git@gitlab.example.com:team/api.git ")
        XCTAssertEqual(store.repositories.first?.gitURL, "git@gitlab.example.com:team/api.git")
    }

    func test_updateRepositoryRejectsDuplicateURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.addRepository(gitURL: "git@github.com:org/web.git")
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

        try store.addRepository(gitURL: "git@github.com:org/api.git")
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

    func test_exportBackupWritesRepositoryBackupDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.addRepository(gitURL: "git@github.com:org/web.git")

        let document = try store.exportBackup(to: backupURL)
        let data = try Data(contentsOf: backupURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RepositoryBackupDocument.self, from: data)

        XCTAssertEqual(document.version, decoded.version)
        XCTAssertEqual(decoded.version, RepositoryBackupDocument.currentVersion)
        XCTAssertEqual(document.repositories, decoded.repositories)
        XCTAssertEqual(decoded.repositories, [
            RepositoryBackupEntry(gitURL: "git@github.com:org/api.git"),
            RepositoryBackupEntry(gitURL: "git@github.com:org/web.git"),
        ])
    }

    func test_importBackupImportsNewRepositoriesAndSkipsDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        try store.addRepository(gitURL: "git@github.com:org/api.git")

        let v1JSON = """
        {
            "version": 1,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": [
                "git@github.com:org/api.git",
                "git@github.com:org/web.git",
                "git@github.com:org/ios.git",
                "git@github.com:team-b/web.git"
            ]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v1JSON.utf8).write(to: backupURL, options: .atomic)

        let result = try store.importBackup(from: backupURL)

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(
            Set(store.repositories.map(\.gitURL)),
            Set([
                "git@github.com:org/api.git",
                "git@github.com:org/web.git",
                "git@github.com:org/ios.git",
            ])
        )
    }

    func test_importBackupRejectsInvalidBackupFormat() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data("{\"repositories\":true}".utf8).write(to: backupURL, options: .atomic)

        XCTAssertThrowsError(
            try store.importBackup(from: backupURL)
        ) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .invalidBackupFormat)
        }
    }

    func test_importBackupRejectsEmptyRepositoryList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")
        let v1JSON = """
        {
            "version": 1,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": []
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v1JSON.utf8).write(to: backupURL, options: .atomic)

        XCTAssertThrowsError(
            try store.importBackup(from: backupURL)
        ) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .emptyBackup)
        }
    }

    func test_exportBackupV2IncludesMRTargetBranches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.updateMRTargetBranches(
            id: store.repositories.first!.id,
            branches: ["develop", "release/v1"]
        )

        let document = try store.exportBackup(to: backupURL)

        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.repositories.count, 1)
        XCTAssertEqual(document.repositories.first?.gitURL, "git@github.com:org/api.git")
        XCTAssertEqual(document.repositories.first?.mrTargetBranches, ["develop", "release/v1"])
    }

    func test_importBackupV1FormatImportsWithEmptyMRTargetBranches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        let v1JSON = """
        {
            "version": 1,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": [
                "git@github.com:org/api.git",
                "git@github.com:org/web.git"
            ]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v1JSON.utf8).write(to: backupURL, options: .atomic)

        let result = try store.importBackup(from: backupURL)

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertTrue(store.repositories.allSatisfy { $0.mrTargetBranches.isEmpty })
    }

    func test_importBackupV2FormatImportsWithMRTargetBranches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        let v2JSON = """
        {
            "version": 2,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": [
                {
                    "gitURL": "git@github.com:org/api.git",
                    "mrTargetBranches": ["develop", "staging"]
                }
            ]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v2JSON.utf8).write(to: backupURL, options: .atomic)

        let result = try store.importBackup(from: backupURL)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(store.repositories.first?.mrTargetBranches, ["develop", "staging"])
    }

    func test_importBackupMergesMRTargetBranchesForExistingRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.updateMRTargetBranches(
            id: store.repositories.first!.id,
            branches: ["develop"]
        )

        let v2JSON = """
        {
            "version": 2,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": [
                {
                    "gitURL": "git@github.com:org/api.git",
                    "mrTargetBranches": ["develop", "staging"]
                },
                {
                    "gitURL": "git@github.com:org/web.git",
                    "mrTargetBranches": ["main"]
                }
            ]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v2JSON.utf8).write(to: backupURL, options: .atomic)

        let result = try store.importBackup(from: backupURL)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.mergedCount, 1)
        let apiRepo = store.repositories.first { $0.repoName == "api" }
        XCTAssertEqual(apiRepo?.mrTargetBranches, ["develop", "staging"])
    }
}
