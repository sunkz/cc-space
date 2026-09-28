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

    // MARK: - rename(2) 原子覆盖

    func test_atomicReplaceOverwritesExistingDestinationAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("target.json")
        let staged = root.appendingPathComponent("staged.json")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: staged)

        try JSONFileStore.atomicReplace(stagedURL: staged, destinationURL: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func test_atomicReplaceThrowsPosixErrorWhenSourceMissing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("does-not-exist.json")
        let destination = root.appendingPathComponent("target.json")

        XCTAssertThrowsError(try JSONFileStore.atomicReplace(stagedURL: missing, destinationURL: destination))
    }

    func test_saveOverwritePreserves0600Permissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore(rootDirectory: root)
        let settings = AppSettings(workplaceRootPath: "/tmp/workplaces")

        try store.save(settings, as: "settings.json")
        // 第二次保存走 rename 覆盖路径:权限应随暂存文件(0600)带到目标。
        try store.save(AppSettings(workplaceRootPath: "/tmp/other"), as: "settings.json")

        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.json").path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o600)
        let loaded: AppSettings = try store.load(AppSettings.self, from: "settings.json")
        XCTAssertEqual(loaded.workplaceRootPath, "/tmp/other")
    }

    // MARK: - 启动清理对备份的保全

    func test_cleanupStaleStagingDirectoriesRescuesBackupBeforeDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 伪造一个"足够老"的崩溃残留暂存目录,内含 backup/settings.json(唯一副本)。
        let staleStaging = root.appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        let backupDirectory = staleStaging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: backupDirectory.appendingPathComponent("settings.json"))
        try fileManager.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: staleStaging.path
        )
        // 同时放一个不含 backup 的普通残留,应被直接删掉。
        let emptyStaging = root.appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: emptyStaging, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: emptyStaging.path
        )

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertFalse(fileManager.fileExists(atPath: staleStaging.path))
        XCTAssertFalse(fileManager.fileExists(atPath: emptyStaging.path))
        // 备份被逃到 rollback-backup 前缀下,内容完好可手工取回。
        let survivors = try fileManager.contentsOfDirectory(atPath: root.path)
        let rescued = survivors.filter { $0.hasPrefix(".ccspace-json-rollback-backup-") }
        XCTAssertEqual(rescued.count, 1)
        let rescuedFile = root
            .appendingPathComponent(rescued[0], isDirectory: true)
            .appendingPathComponent("settings.json")
        XCTAssertEqual(try Data(contentsOf: rescuedFile), Data("precious".utf8))
    }

    func test_cleanupStaleStagingDirectoriesLeavesFreshStagingAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let freshStaging = root.appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: freshStaging, withIntermediateDirectories: true)

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertTrue(fileManager.fileExists(atPath: freshStaging.path))
    }
}
