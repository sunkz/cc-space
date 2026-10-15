import XCTest
@testable import CCSpace

@MainActor
final class RepositoryStoreTests: XCTestCase {
    func test_addRepositoryRejectsDuplicateURL() async throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertThrowsError(
            try store.addRepository(gitURL: "git@github.com:org/..")
        ) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .invalidRepoName)
        }
    }

    func test_removeRepositoryDeletesAndPersists() async throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.addRepository(gitURL: "git@github.com:org/web.git")
        XCTAssertEqual(store.repositories.count, 2)

        let idToRemove = store.repositories[0].id
        try store.removeRepository(id: idToRemove, workplaceStore: workplaceStore)
        XCTAssertEqual(store.repositories.count, 1)
        XCTAssertFalse(store.repositories.contains(where: { $0.id == idToRemove }))

        // Verify persistence
        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.count, 1)
    }

    /// 删仓库必须与工作区关联清理一次原子提交:repositories.json 落盘的同时,
    /// 工作区的选中/置顶列表与 sync states 里的引用一并清掉并持久化。
    func test_removeRepositoryAtomicallyCleansWorkplaceAssociations() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        try store.addRepository(gitURL: "git@github.com:org/web.git")
        let removedRepository = try XCTUnwrap(store.repositories.first { $0.repoName == "api" })
        let keptRepository = try XCTUnwrap(store.repositories.first { $0.repoName == "web" })

        let workplace = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: root.appendingPathComponent("workplaces").path,
            selectedRepositories: [removedRepository, keptRepository]
        )
        try workplaceStore.setRepositoryPinned(true, repositoryID: removedRepository.id, in: workplace.id)

        try store.removeRepository(id: removedRepository.id, workplaceStore: workplaceStore)

        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(updatedWorkplace.selectedRepositoryIDs, [keptRepository.id])
        XCTAssertEqual(updatedWorkplace.pinnedRepositoryIDs, [])
        XCTAssertTrue(workplaceStore.syncStates.allSatisfy { $0.repositoryID != removedRepository.id })

        // 关联清理结果同样落盘(同一份 fileStore,重新加载后无悬空引用)。
        let reloadedWorkplaceStore = WorkplaceStore(fileStore: fileStore)
        let reloadedWorkplace = try XCTUnwrap(reloadedWorkplaceStore.workplaces.first { $0.id == workplace.id })
        XCTAssertEqual(reloadedWorkplace.selectedRepositoryIDs, [keptRepository.id])
        XCTAssertTrue(reloadedWorkplaceStore.syncStates.allSatisfy { $0.repositoryID != removedRepository.id })
    }

    /// "https://x/repo.git/" 与 "https://x/repo" 应视为同一仓库:
    /// 归一化必须循环剥离尾部 "/" 与 ".git",单次剥离会漏判。
    func test_addRepositoryTreatsTrailingSlashAndGitSuffixAsDuplicate() throws {
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: "https://github.com/org/repo")

        XCTAssertThrowsError(
            try store.addRepository(gitURL: "https://github.com/org/repo.git/")
        ) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .duplicateURL)
        }
    }

    func test_addRepositoryTrimsWhitespace() async throws {
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: " git@github.com:org/api.git ")
        XCTAssertEqual(store.repositories.first?.gitURL, "git@github.com:org/api.git")
    }

    /// 去重只做清理,**不得**把磁盘上"看着像仓库"的目录顺手纳管进来。
    ///
    /// 自动纳管是磁盘刷新那条链的既定行为(另测),但去重这条路上多塞记录等于用户
    /// 没同意就多了个仓库。原用例把 store 的 fileStore 与仓库目录指向两个不同临时根、
    /// 且 store 一条记录都没有,`isEmpty` 恒真——断言与实现无关,这里连盘带库都真的摆上。
    func test_deduplicatePersistedRepositoriesDoesNotImportRepositoriesFromDisk() throws {
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: makeTestRootURL()))
        try store.addRepository(gitURL: "git@github.com:org/api.git")

        let diskRoot = makeTestRootURL()
        let fileManager = FileManager.default
        for folder in ["hello", "hi"] {
            try fileManager.createDirectory(
                at: diskRoot.appendingPathComponent(folder).appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }

        store.applyDeduplicationResult(
            RepositoryStore.deduplicationResult(for: store.repositories)
        )

        XCTAssertEqual(store.repositories.map(\.gitURL), ["git@github.com:org/api.git"])
    }

    func test_exportBackupWritesRepositoryBackupDocument() async throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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

    /// 版本校验必须有下界:version 为 0/负数(手工编辑或伪造的备份)不得被当受支持版本导入。
    func test_importBackupRejectsVersionBelowOne() throws {
        let root = makeTestRootURL()
        let backupURL = root.appendingPathComponent("repositories-backup.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for badVersion in [0, -3] {
            let json = """
            {
                "version": \(badVersion),
                "exportedAt": "2024-01-01T00:00:00Z",
                "repositories": [
                    {
                        "gitURL": "git@github.com:org/api.git"
                    }
                ]
            }
            """
            try Data(json.utf8).write(to: backupURL, options: .atomic)
            let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

            XCTAssertThrowsError(
                try store.importBackup(from: backupURL),
                "version \(badVersion) 应被拒绝"
            ) { error in
                XCTAssertEqual(
                    error as? RepositoryStoreError,
                    .unsupportedBackupVersion(badVersion)
                )
            }
            XCTAssertTrue(store.repositories.isEmpty, "非法版本不得导入任何仓库")
        }
    }

    func test_importBackupV2FormatImportsWithMRTargetBranches() throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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

    // MARK: - 去重保留优先级 / 导入容错(回归锁)

    func test_deduplicationKeepsProtectedAndOlderBeforeUnprotectedNewer() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // olderUnprotected:更早但未被引用;referenced:更晚但被工作区引用。
        let olderUnprotected = RepositoryConfig(
            id: UUID(), gitURL: "git@github.com:org/blog.git", repoName: "blog",
            createdAt: now, updatedAt: now
        )
        let referenced = RepositoryConfig(
            id: UUID(), gitURL: "https://github.com/org/blog", repoName: "blog",
            createdAt: now.addingTimeInterval(100), updatedAt: now.addingTimeInterval(100)
        )
        let result = RepositoryStore.deduplicationResult(
            for: [olderUnprotected, referenced],
            protectedRepositoryIDs: [referenced.id]
        )
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.repositories.map(\.id), [referenced.id], "被引用的重复项必须优先保留,即使它更晚")
        // 无保护信息时回退"更早者优先",而非数组顺序。
        let plain = RepositoryStore.deduplicationResult(for: [referenced, olderUnprotected])
        XCTAssertEqual(plain.repositories.map(\.id), [olderUnprotected.id])
        // 输出顺序跟随输入数组,不改变展示序。
        let reordered = RepositoryStore.deduplicationResult(
            for: [referenced, olderUnprotected],
            protectedRepositoryIDs: [referenced.id]
        )
        XCTAssertEqual(reordered.repositories.map(\.id), [referenced.id])
    }

    /// 去重不再硬删丢弃项:字段并入保留项,并产出 dropped→kept 的 id 映射
    /// (10-10 review P2 修复的回归锁)。
    func test_deduplicationMergesFieldsAndProducesIDRemapping() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = RepositoryConfig(
            id: UUID(),
            gitURL: "https://github.com/org/api",
            repoName: "api",
            mrTargetBranches: ["main"],
            createdAt: now,
            updatedAt: now
        )
        let dropped = RepositoryConfig(
            id: UUID(),
            // 同一远端的另一种写法(尾随 `/` + `.git`):归一化后与上面相等,
            // 这才是"重复登记",允许字段并入 + 引用重映射。
            gitURL: "https://github.com/org/api.git/",
            repoName: "api",
            defaultBranch: "master",
            mrTargetBranches: ["main", "dev"],
            createdAt: now.addingTimeInterval(100),
            updatedAt: now.addingTimeInterval(100)
        )
        let result = RepositoryStore.deduplicationResult(for: [kept, dropped])
        XCTAssertEqual(result.repositories.count, 1)
        let survivor = try XCTUnwrap(result.repositories.first)
        XCTAssertEqual(survivor.id, kept.id)
        XCTAssertEqual(survivor.defaultBranch, "master", "缺省才回填")
        XCTAssertEqual(survivor.mrTargetBranches, ["main", "dev"], "保序并集")
        XCTAssertEqual(result.idRemapping[dropped.id], kept.id)
        XCTAssertTrue(result.crossURLNameConflicts.isEmpty, "同 URL 重复不是冲突")
    }

    /// 同名但**不同远端**:只丢弃多余记录、绝不重映射引用。
    ///
    /// 把引用换到另一条上,等于让工作区开始 pull/push 一个它从未配置过的远端,
    /// 而且完全静默(名字一样,界面上看不出区别)。宁可摘除引用让"该仓库缺失"
    /// 显式暴露,由用户重新添加正确的远端。
    func test_deduplicationDoesNotRemapReferencesAcrossDifferentURLsWithSameName() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: now,
            updatedAt: now
        )
        let dropped = RepositoryConfig(
            id: UUID(),
            gitURL: "https://gitlab.com/other/api",
            repoName: "api",
            defaultBranch: "master",
            createdAt: now.addingTimeInterval(100),
            updatedAt: now.addingTimeInterval(100)
        )
        let result = RepositoryStore.deduplicationResult(
            for: [kept, dropped],
            protectedRepositoryIDs: [kept.id]
        )

        XCTAssertEqual(result.repositories.count, 1, "同名不同远端也只能留一条(名字全局唯一 + 目录按名派生)")
        XCTAssertEqual(result.repositories.first?.id, kept.id)
        XCTAssertNil(result.idRemapping[dropped.id], "不同远端之间禁止引用重映射")
        XCTAssertEqual(result.crossURLNameConflicts, ["api"], "冲突必须被记录,便于归因")
        // 字段并入也不许跨远端发生:另一条的 defaultBranch 不得渗进保留项。
        XCTAssertNil(result.repositories.first?.defaultBranch)
    }

    /// 引用重映射:工作区对被删项的选中/置顶换成保留项并按首现去重;
    /// sync-states 同工作区双行时保留存活项原行,孤行改挂保留 id
    /// (10-10 review P2:此前直接摘除引用,工作区白丢仓库)。
    func test_remappingReferencesAndSyncStates() throws {
        let keptID = UUID()
        let droppedID = UUID()
        let workplace = Workplace(
            id: UUID(),
            name: "w",
            path: "/tmp/w",
            selectedRepositoryIDs: [droppedID, keptID],
            pinnedRepositoryIDs: [droppedID],
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let remappedWorkplaces = RepositoryStore.remappingReferences(
            from: [workplace],
            idRemapping: [droppedID: keptID]
        )
        XCTAssertEqual(remappedWorkplaces.first?.selectedRepositoryIDs, [keptID])
        XCTAssertEqual(remappedWorkplaces.first?.pinnedRepositoryIDs, [keptID])

        let workplaceID = UUID()
        let keptRow = RepositorySyncState(
            workplaceID: workplaceID, repositoryID: keptID, status: .success, localPath: "/tmp/w/api"
        )
        let droppedRow = RepositorySyncState(
            workplaceID: workplaceID, repositoryID: droppedID, status: .failed, localPath: "/tmp/w/api"
        )
        let merged = RepositoryStore.remappingSyncStates(
            [keptRow, droppedRow],
            idRemapping: [droppedID: keptID]
        )
        XCTAssertEqual(merged.count, 1, "组合键唯一:存活项原行优先,被删项行丢弃")
        XCTAssertEqual(merged.first?.status, .success)

        let lone = RepositoryStore.remappingSyncStates([droppedRow], idRemapping: [droppedID: keptID])
        XCTAssertEqual(lone.count, 1)
        XCTAssertEqual(lone.first?.repositoryID, keptID)
    }

    /// 建档返回实时记录(调用方不必再按地址回查——10-10 review P2 的"两步写"死角
    /// 就是靠"一次落盘 + 返回记录"消掉的);MR 目标分支改由面板单独配置,同样要落盘。
    func test_addRepositoryReturnsLiveRecordAndPersistsBranchUpdates() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = RepositoryStore(fileStore: fileStore)

        let created = try store.addRepository(gitURL: "git@github.com:org/api.git")
        // 建档自己就得把记录落盘:后面的写会全量重排整个数组,若不在这里单独 reload,
        // "addRepository 是否真的写过盘"会被下一次写顺带掩盖。
        let afterAdd = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(afterAdd.repositories.count, 1)
        XCTAssertEqual(afterAdd.repositories.first?.id, created.id)

        try store.updateMRTargetBranches(id: created.id, branches: ["main", "dev"])

        let stored = try XCTUnwrap(store.repositories.first)
        XCTAssertEqual(created.id, stored.id)
        XCTAssertEqual(created.mrTargetBranches, [], "建档时不带 MR 分支")
        XCTAssertEqual(stored.mrTargetBranches, ["main", "dev"])

        let reloaded = RepositoryStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.repositories.first?.mrTargetBranches, ["main", "dev"])
    }

    /// 本地路径的 `~` 在建档时展开:git 子进程不经过 shell,原样入库的地址
    /// `ls-remote`/`clone` 都会把它当字面量目录名,永远失败。
    func test_addRepositoryExpandsHomeDirectoryPrefix() throws {
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: makeTestRootURL()))

        let created = try store.addRepository(gitURL: "~/repos/blog.git")
        XCTAssertEqual(created.gitURL, NSHomeDirectory() + "/repos/blog.git")

        // 展开后再加一次同一个远端:归一化必须认出重复,而不是存两条。
        XCTAssertThrowsError(try store.addRepository(gitURL: "~/repos/blog.git")) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .duplicateURL)
        }
        // scp 形态里的 `~` 属远端 shell 语义,不能动。
        let remote = try store.addRepository(gitURL: "git@host:~/srv/blog2.git")
        XCTAssertEqual(remote.gitURL, "git@host:~/srv/blog2.git")
    }

    /// 大小写不同但指向同一仓库的地址必须判等:`GitHub.com/Org/API` 与
    /// `github.com/org/api` 存成两条记录,克隆时它们推出来的 repoName 相同、
    /// 会抢同一个工作区目录,而第二份记录在 UI 上看着像"另一个仓库"。
    func test_gitURLsMatchIgnoresCaseAndTrailingSeparators() {
        XCTAssertTrue(
            RepositoryStore.gitURLsMatch("https://github.com/org/api.git", "https://GitHub.COM/Org/API")
        )
        XCTAssertTrue(
            RepositoryStore.gitURLsMatch("git@github.com:org/api.git", "GIT@github.com:org/api/")
        )
        XCTAssertFalse(
            RepositoryStore.gitURLsMatch("https://github.com/org/api.git", "https://github.com/org/apiv2.git")
        )
    }

    func test_addRepositoryRejectsCaseVariantOfExistingURL() throws {
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: makeTestRootURL()))
        try store.addRepository(gitURL: "https://github.com/org/api.git")

        XCTAssertThrowsError(try store.addRepository(gitURL: "https://GitHub.com/Org/API.git")) { error in
            XCTAssertEqual(error as? RepositoryStoreError, .duplicateURL)
        }
    }

    /// 备份文件可被手工编辑,导入侧与新增入口同一口径展开 `~/`:原样入库就是一个
    /// 永远克隆不下来的死地址(git 不展波浪号,这里也从不经过 shell)。
    func test_importBackupExpandsHomeDirectoryPrefix() throws {
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("repositories-backup.json")
        let v2JSON = """
        {
            "version": 2,
            "exportedAt": "2024-01-01T00:00:00Z",
            "repositories": [
                { "gitURL": "~/remotes/blog.git" }
            ]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(v2JSON.utf8).write(to: backupURL, options: .atomic)

        _ = try store.importBackup(from: backupURL)

        XCTAssertEqual(store.repositories.map(\.gitURL), [NSHomeDirectory() + "/remotes/blog.git"])
    }

    /// 口径一致性:UI 判定通过的地址,Store 建档必须也能成功(反之则用户会看到
    /// "地址格式正确却报第三种错")。这里是新增入口放行的各类形态的最小代表集。
    func test_repositoryURLShapesAcceptedByUIAreStorable() throws {
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: makeTestRootURL()))

        for gitURL in [
            "https://github.com/org/blog.git",
            "ssh://git@github.com:22/org/blog2.git",
            "git@github.com:org/blog3.git",
            "github.com:org/blog9.git",
            "git@gitlab.example.com:group/sub/blog4.git",
            "git@host:/srv/git/blog5.git",
            "https://host/org/my%20repo.git",
            "file:///private/tmp/remotes/blog6.git",
            "/private/tmp/remotes/blog7.git",
            "~/remotes/blog8.git",
        ] {
            XCTAssertTrue(RepositoryURLFormat.isParseable(gitURL), "UI 侧应放行 \(gitURL)")
            XCTAssertNoThrow(try store.addRepository(gitURL: gitURL), "Store 建档应接受 \(gitURL)")
        }
    }

    /// 去重事件序号必须单调递增:根视图用 `.onChange` 观察事件,而清理条数可能
    /// 连续两次相同(1→1),按条数观察第二次不会触发、提示永久丢失。
    func test_applyDeduplicationResultBumpsSequenceWhenCleanupCountRepeats() throws {
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        XCTAssertNil(store.lastDeduplicationCleanupCount)
        XCTAssertEqual(store.deduplicationCleanupSequence, 0)

        try store.addRepository(gitURL: "git@github.com:org/api.git")
        store.applyDeduplicationResult(
            RepositoryDeduplicationResult(repositories: [], changed: true)
        )
        XCTAssertEqual(store.lastDeduplicationCleanupCount, 1)
        XCTAssertEqual(store.deduplicationCleanupSequence, 1)

        // 第二次清理条数与上次相同(1→1):onChange(按条数)不会触发,序号必须前进。
        try store.addRepository(gitURL: "git@github.com:org/web.git")
        store.applyDeduplicationResult(
            RepositoryDeduplicationResult(repositories: [], changed: true)
        )
        XCTAssertEqual(store.lastDeduplicationCleanupCount, 1, "两次清理条数相同")
        XCTAssertEqual(store.deduplicationCleanupSequence, 2, "事件序号仍前进,第二次事件不丢")
    }

    func test_importBackupSkipsInvalidEntryAndKeepsRest() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))
        let backupURL = root.appendingPathComponent("backup.json")
        let json = """
        {"version":2,"exportedAt":"2026-01-01T00:00:00Z","repositories":[{"gitURL":"git@github.com:org/good-one.git"},{"gitURL":"https://github.com/org/.."},{"gitURL":"git@github.com:org/good-two.git"}]}
        """
        try json.write(to: backupURL, atomically: true, encoding: .utf8)

        let result = try store.importBackup(from: backupURL)

        XCTAssertEqual(result.importedCount, 2, "一条坏数据不得毁掉整个导入")
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(Set(store.repositories.map(\.repoName)), ["good-one", "good-two"])
    }

    /// repositories.json 混入重复 id(两条不同 URL)时加载必须收敛:
    /// 否则去重的 keptIDs(Set<UUID>)会把同 id 两条都判为保留,更新/删除只可达首条。
    func test_duplicateRepositoryIDsAreDeduplicatedOnLoad() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let now = Date()
        let first = RepositoryConfig(
            id: id,
            gitURL: "git@github.com:org/blog.git",
            repoName: "blog",
            createdAt: now,
            updatedAt: now
        )
        let second = RepositoryConfig(
            id: id,
            gitURL: "git@github.com:org/web.git",
            repoName: "web",
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONFileStore.makeEncoder().encode([first, second])
        try data.write(to: root.appendingPathComponent("repositories.json"))

        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.repositories.count, 1, "重复 id 的仓库应在加载时收敛到首条")
        XCTAssertEqual(store.repositories.first?.repoName, "blog")
    }

    /// mrTargetBranches 的"无重复"是不变量:此前只在 decode 路径去重,
    /// 成员式构造(新增仓库弹窗、导入前的内存对象)可带着重复值进入
    /// `ForEach(id: \.self)`,造成 SwiftUI 重复 ID。两条路径必须都收敛。
    func test_repositoryConfigDeduplicatesMRTargetBranchesOnBothPaths() throws {
        let now = Date()
        let constructed = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/blog.git",
            repoName: "blog",
            mrTargetBranches: ["main", "develop", "main"],
            createdAt: now,
            updatedAt: now
        )
        XCTAssertEqual(constructed.mrTargetBranches, ["main", "develop"], "构造路径应保序去重")

        let json = """
        {
            "id": "\(constructed.id.uuidString)",
            "gitURL": "git@github.com:org/blog.git",
            "repoName": "blog",
            "mrTargetBranches": ["develop", "main", "develop", "release/1"],
            "createdAt": "2024-01-01T00:00:00Z",
            "updatedAt": "2024-01-01T00:00:00Z"
        }
        """
        let decoded = try JSONFileStore.makeDecoder().decode(
            RepositoryConfig.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.mrTargetBranches, ["develop", "main", "release/1"], "解码路径保持保序去重")
    }

    // MARK: - commitDiskRefresh(刷新结果 + 去重删除单批原子提交)
    func test_commitDiskRefreshPrunesReferencesAndPersistsAtomically() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let repositoryStore = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        try repositoryStore.addRepository(gitURL: "git@github.com:org/web.git")
        let kept = repositoryStore.repositories[0]
        let removed = repositoryStore.repositories[1]
        let workplace = try workplaceStore.createWorkplace(
            name: "demo",
            rootPath: "/Users/demo/Workplaces",
            selectedRepositories: repositoryStore.repositories
        )
        try workplaceStore.setRepositoryPinned(true, repositoryID: removed.id, in: workplace.id)

        let repositoryResult = RepositoryDeduplicationResult(repositories: [kept], changed: true)
        // changed=false 也要提交:去重引用清理本身就是变化(旧两步写的缺口)。
        let workplaceResult = WorkplaceDiskRefreshResult(
            workplaces: workplaceStore.workplaces,
            syncStates: workplaceStore.syncStates,
            changed: false
        )

        try repositoryStore.commitDiskRefresh(
            workplaceResult: workplaceResult,
            repositoryResult: repositoryResult,
            workplaceStore: workplaceStore
        )

        XCTAssertEqual(repositoryStore.repositories.map(\.id), [kept.id])
        XCTAssertEqual(repositoryStore.lastDeduplicationCleanupCount, 1)
        XCTAssertEqual(repositoryStore.deduplicationCleanupSequence, 1)
        let updatedWorkplace = try XCTUnwrap(workplaceStore.workplaces.first)
        XCTAssertEqual(updatedWorkplace.selectedRepositoryIDs, [kept.id], "被删仓库的选中引用应同批清理")
        XCTAssertTrue(updatedWorkplace.pinnedRepositoryIDs.isEmpty, "置顶引用同样要摘除")
        XCTAssertEqual(Set(workplaceStore.syncStates.map(\.repositoryID)), [kept.id])

        let reloadedRepositoryStore = RepositoryStore(fileStore: fileStore)
        let reloadedWorkplaceStore = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedRepositoryStore.repositories.map(\.id), [kept.id])
        XCTAssertEqual(reloadedWorkplaceStore.workplaces.first?.selectedRepositoryIDs, [kept.id])
        XCTAssertEqual(Set(reloadedWorkplaceStore.syncStates.map(\.repositoryID)), [kept.id])
    }

    func test_commitDiskRefreshWithNoChangesWritesNothing() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let repositoryStore = RepositoryStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        try repositoryStore.addRepository(gitURL: "git@github.com:org/blog.git")
        _ = try workplaceStore.createWorkplace(
            name: "demo",
            rootPath: "/Users/demo/Workplaces",
            selectedRepositories: repositoryStore.repositories
        )
        workplaceStore.flushSyncStates()

        let mtimeBefore = try fileModificationDate(
            of: root.appendingPathComponent("repositories.json").path
        )
        let snapshot = WorkplaceStore.snapshot(
            workplaces: workplaceStore.workplaces,
            syncStates: workplaceStore.syncStates
        )
        let workplaceResult = WorkplaceDiskRefreshResult(
            workplaces: snapshot.workplaces,
            syncStates: snapshot.syncStates,
            changed: false
        )
        let repositoryResult = RepositoryDeduplicationResult(
            repositories: repositoryStore.repositories,
            changed: false
        )

        try repositoryStore.commitDiskRefresh(
            workplaceResult: workplaceResult,
            repositoryResult: repositoryResult,
            workplaceStore: workplaceStore
        )

        XCTAssertEqual(repositoryStore.deduplicationCleanupSequence, 0)
        let mtimeAfter = try fileModificationDate(
            of: root.appendingPathComponent("repositories.json").path
        )
        XCTAssertEqual(mtimeAfter, mtimeBefore, "无任何变化时不得触发落盘写")
    }

    /// 读取文件的修改时间。**不能用 `try?` + `?? .distantPast`**:attributes 读取
    /// 失败(文件被误删、权限问题)时前后两次都会变成 `.distantPast`,
    /// "mtime 未变化"的断言于是空转通过——恰恰在"文件根本没了"时最该红。
    private func fileModificationDate(of path: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(
            attributes[.modificationDate] as? Date,
            "读不到 mtime:\(path)"
        )
    }
}
