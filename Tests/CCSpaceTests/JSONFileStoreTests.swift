import XCTest
@testable import CCSpace

final class JSONFileStoreTests: XCTestCase {
    func test_roundTripsRepositories() throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("does-not-exist.json")
        let destination = root.appendingPathComponent("target.json")

        XCTAssertThrowsError(try JSONFileStore.atomicReplace(stagedURL: missing, destinationURL: destination))
    }

    func test_saveOverwritePreserves0600Permissions() throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let freshStaging = root.appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: freshStaging, withIntermediateDirectories: true)

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertTrue(fileManager.fileExists(atPath: freshStaging.path))
    }

    func test_cleanupStaleStagingDirectoriesKeepsStagingWhenBackupRescueFails() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let staleStaging = root.appendingPathComponent(".ccspace-json-write-\(UUID().uuidString)", isDirectory: true)
        let backupDirectory = staleStaging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let preciousFile = backupDirectory.appendingPathComponent("settings.json")
        try Data("precious".utf8).write(to: preciousFile)
        try fileManager.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: staleStaging.path
        )

        // move 失败(此处注入权限类异常)时绝不能删暂存目录:
        // 恰在移动失败——即"被覆写前唯一副本"最需要保全——的时刻把它销毁违背清理意图。
        JSONFileStore.cleanupStaleStagingDirectories(
            in: root,
            fileManager: MoveFailingFileManager()
        )

        XCTAssertTrue(fileManager.fileExists(atPath: staleStaging.path))
        XCTAssertEqual(try Data(contentsOf: preciousFile), Data("precious".utf8))
    }

    // MARK: - 多文档事务的崩溃收敛(意图清单)

    func test_saveMultiDocumentLeavesNoTransactionManifestOrStaging() throws {
        let root = makeTestRootURL()
        let store = JSONFileStore(rootDirectory: root)

        let doc1 = try store.document(for: AppSettings(workplaceRootPath: "/a"), as: "settings.json")
        let doc2 = try store.document(for: ["x"], as: "workplaces.json")
        try store.save([doc1, doc2])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".ccspace-json-txn-") })
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".ccspace-json-write-") })
    }

    func test_startupRecoveryRollsBackInterruptedMultiDocumentCommit() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 模拟"两次 rename 之间崩溃":a.json 已提交(目标为新值,暂存里有旧值备份),
        // b.json 未提交(目标仍是旧值,暂存里是新值待改名)。
        try Data("NEW-A".utf8).write(to: root.appendingPathComponent("a.json"))
        try Data("OLD-B".utf8).write(to: root.appendingPathComponent("b.json"))
        let stagingName = ".ccspace-json-write-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        let backup = staging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("OLD-A".utf8).write(to: backup.appendingPathComponent("a.json"))
        try Data("NEW-B".utf8).write(to: staging.appendingPathComponent("b.json"))
        try writeManifest(stagingName: stagingName, fileNames: ["a.json", "b.json"], in: root, modificationDate: Date().addingTimeInterval(-30))

        JSONFileStore.cleanupStaleStagingDirectories(in: root, olderThan: 0)

        // 回滚到"全旧"自洽态:不能出现设置指新值、记录指旧值的混合态。
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.json"), encoding: .utf8), "OLD-A")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.json"), encoding: .utf8), "OLD-B")
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
        let manifests = try fileManager.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".ccspace-json-txn-") }
        XCTAssertTrue(manifests.isEmpty)
    }

    func test_startupRecoveryRollsBackNewlyCreatedDocumentsOfInterruptedCommit() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 崩溃点:a.json 已改名提交(有备份),sync-states.json 是本事务新建并搬入的
        // (无备份),c.json 尚未处理(暂存文件仍在)。清单里只要还有未处理文档就是
        // "未完成提交",已搬入的新文件必须被撤销删除。
        try Data("NEW-A".utf8).write(to: root.appendingPathComponent("a.json"))
        try Data("OLD-C".utf8).write(to: root.appendingPathComponent("c.json"))
        try Data("NEW-STATE".utf8).write(to: root.appendingPathComponent("sync-states.json"))
        let stagingName = ".ccspace-json-write-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        let backup = staging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("OLD-A".utf8).write(to: backup.appendingPathComponent("a.json"))
        try Data("NEW-C".utf8).write(to: staging.appendingPathComponent("c.json"))
        try writeManifest(
            stagingName: stagingName,
            fileNames: ["a.json", "sync-states.json", "c.json"],
            in: root,
            modificationDate: Date().addingTimeInterval(-30)
        )

        JSONFileStore.cleanupStaleStagingDirectories(in: root, olderThan: 0)

        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("sync-states.json").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.json"), encoding: .utf8), "OLD-A")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("c.json"), encoding: .utf8), "OLD-C")
    }

    func test_startupRecoveryForwardRollsCompletedCommitWithStaleManifest() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 全部提交完成,只是"删清单 + 删暂存"之间崩溃:暂存文件全部消失、备份还在。
        // 此刻清单残留必须判为"已提交"→ 前滚(仅清残留),不得把新数据回滚掉。
        try Data("NEW-A".utf8).write(to: root.appendingPathComponent("a.json"))
        try Data("NEW-B".utf8).write(to: root.appendingPathComponent("b.json"))
        let stagingName = ".ccspace-json-write-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        let backup = staging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("OLD-A".utf8).write(to: backup.appendingPathComponent("a.json"))
        try Data("OLD-B".utf8).write(to: backup.appendingPathComponent("b.json"))
        try writeManifest(stagingName: stagingName, fileNames: ["a.json", "b.json"], in: root, modificationDate: Date().addingTimeInterval(-30))

        JSONFileStore.cleanupStaleStagingDirectories(in: root, olderThan: 0)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.json"), encoding: .utf8), "NEW-A")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.json"), encoding: .utf8), "NEW-B")
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    /// 崩溃后用户继续使用、目标文件已被合法重写:陈旧清单在之后的启动里
    /// 不得把"崩溃之后的新数据"回滚吞掉(10-10 review P1 防线)。
    func test_startupRecoverySkipsRollbackForFilesRewrittenAfterCrash() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 崩溃发生在 1 小时前(a.json 已被事务提交,backup=OLD-A);
        // 崩溃后用户继续使用,a.json 于"现在"被合法重写为 POST-CRASH-A。
        try Data("POST-CRASH-A".utf8).write(to: root.appendingPathComponent("a.json"))
        try Data("OLD-B".utf8).write(to: root.appendingPathComponent("b.json"))
        let stagingName = ".ccspace-json-write-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        let backup = staging.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("OLD-A".utf8).write(to: backup.appendingPathComponent("a.json"))
        try Data("NEW-B".utf8).write(to: staging.appendingPathComponent("b.json"))
        try writeManifest(
            stagingName: stagingName,
            fileNames: ["a.json", "b.json"],
            in: root,
            modificationDate: Date().addingTimeInterval(-3600)
        )

        JSONFileStore.cleanupStaleStagingDirectories(in: root, olderThan: 0)

        // a.json 的 mtime 比清单晚出阈值 → 判为崩溃后重写,跳过换回;
        // b.json 从未提交,目标保持旧值;残留清单与暂存被前滚清理。
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.json"), encoding: .utf8), "POST-CRASH-A")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.json"), encoding: .utf8), "OLD-B")
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
        let manifests = try fileManager.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".ccspace-json-txn-") }
        XCTAssertTrue(manifests.isEmpty)
    }

    func test_startupRecoveryLeavesFreshManifestAlone() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try Data("OLD-A".utf8).write(to: root.appendingPathComponent("a.json"))
        let stagingName = ".ccspace-json-write-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("NEW-A".utf8).write(to: staging.appendingPathComponent("a.json"))
        let manifestURL = try writeManifest(
            stagingName: stagingName,
            fileNames: ["a.json"],
            in: root,
            modificationDate: Date()
        )
        // 新清单可能是并发实例的在途写入(默认阈值 10 分钟),不得回滚。

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.json"), encoding: .utf8), "OLD-A")
    }

    @discardableResult
    private func writeManifest(
        stagingName: String,
        fileNames: [String],
        in root: URL,
        modificationDate: Date = .distantPast
    ) throws -> URL {
        struct TestManifest: Encodable {
            let stagingDirectoryName: String
            let fileNames: [String]
        }
        let data = try JSONEncoder().encode(
            TestManifest(stagingDirectoryName: stagingName, fileNames: fileNames)
        )
        let url = root.appendingPathComponent(".ccspace-json-txn-\(UUID().uuidString).json")
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - rename 前 fsync

    func test_fsyncFileSucceedsOnExistingFileAndThrowsOnMissing() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("data.json")
        try Data("{}".utf8).write(to: fileURL)

        try JSONFileStore.fsyncFile(atPath: fileURL.path)

        XCTAssertThrowsError(
            try JSONFileStore.fsyncFile(atPath: root.appendingPathComponent("missing.json").path)
        )
    }

    /// 目录 fsync:open 需以 O_RDONLY(非 FREAD)才能对目录生效;不存在的路径必须抛错。
    /// 生产路径以 `try?` 调用(刷写失败降级不阻断提交),故这里只断言 API 语义本身。
    func test_fsyncDirectorySucceedsOnExistingDirectoryAndThrowsOnMissing() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try JSONFileStore.fsyncDirectory(atPath: root.path)

        XCTAssertThrowsError(
            try JSONFileStore.fsyncDirectory(atPath: root.appendingPathComponent("missing-dir").path)
        )
    }

    // MARK: - 损坏副本与回滚备份的保留策略

    /// 损坏副本此前会永久累积(其中 settings.json 的副本含明文 API Key),
    /// 必须只保留最近 5 份。
    func test_preserveCorruptFileKeepsOnlyFiveMostRecentCopies() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        let store = JSONFileStore(rootDirectory: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("settings.json")

        for index in 0..<8 {
            try Data("{\"apiKey\":\"secret-\(index)\"}".utf8).write(to: source)
            store.preserveCorruptFile(named: "settings.json")
        }

        let copies = try fileManager.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("settings.json.corrupt-") }
        XCTAssertEqual(copies.count, 5, "损坏副本必须只保留最近 5 份")
        // 保全优先改名(move):原文件必须已不在原地,否则后续保存会把它覆写成空数据。
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        // 副本含明文 API Key,必须收紧为仅本人可读写。
        let copyAttributes = try fileManager.attributesOfItem(
            atPath: root.appendingPathComponent(copies[0]).path
        )
        XCTAssertEqual(copyAttributes[.posixPermissions] as? Int, 0o600)
    }

    /// 源文件不存在时保全必须是无害空操作,不得凭空造出空副本
    /// (空副本会被误当成"损坏内容"误导排查)。
    func test_preserveCorruptFileIsNoOpWhenSourceMissing() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        let store = JSONFileStore(rootDirectory: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        store.preserveCorruptFile(named: "workplaces.json")

        let entries = try fileManager.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(entries.isEmpty, "源文件不存在时不得生成空副本: \(entries)")
    }

    /// 回滚备份目录逃过暂存目录清理(否则"可手工取回"落空),但并非永久保留:
    /// 仅"超出保留份数 **且** 超过 24h 龄期"的才回收。
    func test_startupCleanupPrunesAgedRollbackBackupsBeyondRetentionCount() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try makeRollbackBackups(count: 5, in: root, ageHours: 48)

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertEqual(
            try rollbackBackupNames(in: root).count,
            3,
            "超出保留份数(3)且已过龄期的备份必须回收,否则会无限累积"
        )
    }

    /// 年龄下限优先于保留份数:刚产生的备份(崩溃循环下用户尚未取回、且含明文 API Key)
    /// 绝不能在下次启动就被剪掉。
    func test_startupCleanupKeepsFreshRollbackBackupsBeyondRetentionCount() throws {
        let root = makeTestRootURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try makeRollbackBackups(count: 5, in: root, ageHours: 0)

        JSONFileStore.cleanupStaleStagingDirectories(in: root)

        XCTAssertEqual(
            try rollbackBackupNames(in: root).count,
            5,
            "未过 24h 龄期的备份一份都不许剪"
        )
    }

    private func makeRollbackBackups(count: Int, in root: URL, ageHours: Double) throws {
        for index in 0..<count {
            let backup = root.appendingPathComponent(
                ".ccspace-json-rollback-backup-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageHours * 3600)],
                ofItemAtPath: backup.path
            )
        }
    }

    private func rollbackBackupNames(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".ccspace-json-rollback-backup-") }
    }
}

/// 注入 move 失败的 FileManager 替身:验证备份逃生失败时暂存目录被整体保留。
private final class MoveFailingFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw POSIXError(.EACCES)
    }
}
