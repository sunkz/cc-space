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

    func test_updateRepositoryChangesURLWithoutChangingRepoName() async throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
        let store = RepositoryStore(fileStore: JSONFileStore(rootDirectory: root))

        try store.addRepository(gitURL: " git@github.com:org/api.git ")
        let repoID = try XCTUnwrap(store.repositories.first?.id)
        XCTAssertEqual(store.repositories.first?.gitURL, "git@github.com:org/api.git")

        try store.updateRepository(id: repoID, gitURL: " git@gitlab.example.com:team/api.git ")
        XCTAssertEqual(store.repositories.first?.gitURL, "git@gitlab.example.com:team/api.git")
    }

    func test_updateRepositoryRejectsDuplicateURL() async throws {
        let root = makeTestRootURL()
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
        let root = makeTestRootURL()
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
        let rootDirectory = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: makeTestRootURL())
        let store = RepositoryStore(fileStore: fileStore)

        let workplaceA = rootDirectory.appendingPathComponent("hello")
        let workplaceB = rootDirectory.appendingPathComponent("hi")
        let repoA = workplaceA.appendingPathComponent("blog")
        let repoB = workplaceB.appendingPathComponent("blog-copy")

        try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB.appendingPathComponent(".git"), withIntermediateDirectories: true)

        _ = rootDirectory
        store.applyDeduplicationResult(
            RepositoryStore.deduplicationResult(for: store.repositories)
        )

        XCTAssertTrue(store.repositories.isEmpty)
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

        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("repositories.json").path)[.modificationDate] as? Date) ?? .distantPast
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
        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("repositories.json").path)[.modificationDate] as? Date) ?? .distantPast
        XCTAssertEqual(mtimeAfter, mtimeBefore, "无任何变化时不得触发落盘写")
    }

}
