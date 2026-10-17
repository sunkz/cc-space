import XCTest
@testable import CCSpace

@MainActor
final class SettingsStoreTests: XCTestCase {
    func test_defaultsToEmptyRootPathWhenNoSettingsFile() {
        let root = makeTestRootURL()
        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.settings.workplaceRootPath, "")
    }

    func test_updateRootPathPersistsAndLoadsFromNewStore() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)

        try firstStore.updateRootPath(
            "/tmp/workplaces",
            rebasingWorkplaceStore: WorkplaceStore(fileStore: fileStore)
        )

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(secondStore.settings.workplaceRootPath, "/tmp/workplaces")
    }

    /// 换根与工作区路径迁移必须一次原子提交:settings.json、workplaces.json、
    /// sync-states.json 同时更新,不能出现"记录指向新根而设置仍是旧根"的中间态。
    func test_updateRootPathWithRebasingAtomicallyPersistsSettingsAndWorkplaces() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let settingsStore = SettingsStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        try settingsStore.updateRootPath(
            "/Users/demo/OldWorkplaces",
            rebasingWorkplaceStore: workplaceStore
        )
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        _ = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: "/Users/demo/OldWorkplaces",
            selectedRepositories: [repository]
        )

        let rebasedCount = try settingsStore.updateRootPath(
            "/Users/demo/NewWorkplaces",
            rebasingWorkplaceStore: workplaceStore
        )

        XCTAssertEqual(rebasedCount, 1)
        XCTAssertEqual(settingsStore.settings.workplaceRootPath, "/Users/demo/NewWorkplaces")
        XCTAssertEqual(workplaceStore.workplaces.first?.path, "/Users/demo/NewWorkplaces/ios-dev")
        XCTAssertEqual(workplaceStore.syncStates.first?.localPath, "/Users/demo/NewWorkplaces/ios-dev/api")

        // 三个文档同批落盘:重新加载后设置与工作区路径一致,不存在中间态。
        let reloadedSettings = SettingsStore(fileStore: fileStore)
        let reloadedWorkplaces = WorkplaceStore(fileStore: fileStore)
        XCTAssertEqual(reloadedSettings.settings.workplaceRootPath, "/Users/demo/NewWorkplaces")
        XCTAssertEqual(reloadedWorkplaces.workplaces.first?.path, "/Users/demo/NewWorkplaces/ios-dev")
        XCTAssertEqual(reloadedWorkplaces.syncStates.first?.localPath, "/Users/demo/NewWorkplaces/ios-dev/api")
    }

    /// 落盘失败时整体回滚:设置与工作区记录都保持原样(内存态不被半更新)。
    func test_updateRootPathWithRebasingLeavesStateUntouchedWhenPersistFails() throws {
        // root 无视目录写权限,只读前置造不出失败,跳过。
        try XCTSkipIf(geteuid() == 0, "root 身份下只读目录不生效")
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let settingsStore = SettingsStore(fileStore: fileStore)
        let workplaceStore = WorkplaceStore(fileStore: fileStore)
        try settingsStore.updateRootPath(
            "/Users/demo/OldWorkplaces",
            rebasingWorkplaceStore: workplaceStore
        )
        let repository = RepositoryConfig(
            id: UUID(),
            gitURL: "git@github.com:org/api.git",
            repoName: "api",
            createdAt: .now,
            updatedAt: .now
        )
        _ = try workplaceStore.createWorkplace(
            name: "ios-dev",
            rootPath: "/Users/demo/OldWorkplaces",
            selectedRepositories: [repository]
        )

        // 把数据目录改成只读,让换根的原子提交必然失败。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        XCTAssertThrowsError(
            try settingsStore.updateRootPath(
                "/Users/demo/NewWorkplaces",
                rebasingWorkplaceStore: workplaceStore
            )
        )

        XCTAssertEqual(settingsStore.settings.workplaceRootPath, "/Users/demo/OldWorkplaces")
        XCTAssertEqual(workplaceStore.workplaces.first?.path, "/Users/demo/OldWorkplaces/ios-dev")
    }

    func test_encodingSettingsOnlyPersistsWorkplaceRootPath() throws {
        let settings = AppSettings(workplaceRootPath: "/tmp/workplaces")

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("workplaceRootPath"))
        XCTAssertFalse(json.contains("editorCommand"))
    }

    /// 启动(构造)只读不写:旧版本文件(含已移除的 aiSettings 字段)解码正常、原样保留,
    /// 构造路径不得有迁移/改写副作用。
    func test_constructionLoadsLegacyFileWithoutRewriting() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyJSON = """
        {"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm","apiKey":"legacy-secret"}}
        """
        let settingsURL = root.appendingPathComponent("settings.json")
        try legacyJSON.write(to: settingsURL, atomically: true, encoding: .utf8)

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.settings.workplaceRootPath, "/Users/demo/Workplaces", "构造读入完整配置")
        XCTAssertEqual(
            try String(contentsOf: settingsURL, encoding: .utf8),
            legacyJSON,
            "构造不得改写 settings.json"
        )
    }

    func test_saveRootPathErrorMessageWhenPersistFails() throws {
        let rootFileURL = makeTestRootURL()
        try Data("occupied".utf8).write(to: rootFileURL, options: .atomic)

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: rootFileURL))
        let errorMessage = store.saveRootPathAndReturnErrorMessage(
            "/tmp/workplaces",
            rebasingWorkplaceStore: WorkplaceStore(fileStore: JSONFileStore(rootDirectory: rootFileURL))
        )

        XCTAssertNotNil(errorMessage)
        XCTAssertTrue(errorMessage?.contains("保存失败") == true)
    }

    func test_updateAppearanceModePersistsAndLoadsFromNewStore() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)

        try firstStore.updateAppearanceMode(.dark)

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(secondStore.settings.appearanceMode, .dark)
    }

    func test_decodingSettingsWithoutAppearanceModeFallsBackToSystem() throws {
        let legacyJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces"}"#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func test_decodingSettingsWithUnknownAppearanceModeFallsBackToSystemInsteadOfFailing() throws {
        let futureJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","appearanceMode":"auto"}"#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(futureJSON.utf8)
        )

        XCTAssertEqual(settings.workplaceRootPath, "/Users/demo/Workplaces")
        XCTAssertEqual(settings.appearanceMode, .system)
    }

    /// 防抖回归:换根前 500ms 内有 pending 的防抖写入时,换根必须取消防抖任务,
    /// 否则旧快照稍后落盘会把 workplaceRootPath 覆写回旧根——而工作区记录已 rebase
    /// 到新根,下次磁盘刷新会把工作区误判为 missing 删除。
    func test_updateRootPathCancelsPendingDebouncedWrite() async throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore)
        try store.updateRootPath("/Users/demo/OldWorkplaces", rebasingWorkplaceStore: WorkplaceStore(fileStore: fileStore))

        // 触发一次防抖写入(500ms 后才落盘),紧接着立即换根。
        store.updateLastSelectedRoute("workplace")
        try store.updateRootPath("/Users/demo/NewWorkplaces", rebasingWorkplaceStore: WorkplaceStore(fileStore: fileStore))

        // 落盘内容必须始终是新根(防抖任务已被换根取消,旧快照不得覆写)。
        // 用"截止时间 + 50ms 轮询"代替固定 800ms 后单次断言:慢 CI 上调度抖动
        // 不会造成假失败,且覆盖整个防抖窗口,旧快照任何时刻落盘都会被抓到。
        let deadline = Date().timeIntervalSince1970 + 2
        while Date().timeIntervalSince1970 < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let reloaded = SettingsStore(fileStore: fileStore)
            XCTAssertEqual(
                reloaded.settings.workplaceRootPath,
                "/Users/demo/NewWorkplaces",
                "防抖窗口内落盘内容被覆写回旧根"
            )
        }
    }

    /// 换根失败不得取消 pending 的防抖写:取消后不补排会让内存与 settings.json
    /// 短期背离(要等下次变更或退出时的 flush 才收敛)。
    /// 判别点:失败路径下防抖任务必须仍然活着——到点 flush 仍失败会进入重试,
    /// `flushRetryCount` 由 0 变正数;若换根在 save 之前就取消(旧实现),计数恒为 0。
    func test_updateRootPathFailureKeepsPendingDebouncedWrite() async throws {
        // root 用文件占位:save 必然失败(同 test_saveRootPathErrorMessageWhenPersistFails)。
        let rootFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: rootFileURL, options: .atomic)
        let fileStore = JSONFileStore(rootDirectory: rootFileURL)
        let store = SettingsStore(fileStore: fileStore, flushRetryBaseSeconds: 0)

        store.updateLastSelectedRoute("workplaces") // 500ms 防抖后才落盘

        XCTAssertThrowsError(
            try store.updateRootPath(
                "/Users/demo/NewWorkplaces",
                rebasingWorkplaceStore: WorkplaceStore(fileStore: fileStore)
            ),
            "前置:换根写盘失败"
        )
        XCTAssertEqual(store.flushRetryCount, 0, "前置:尚未有任何 flush")

        let deadline = Date().timeIntervalSince1970 + 2
        while Date().timeIntervalSince1970 < deadline, store.flushRetryCount == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertGreaterThan(
            store.flushRetryCount,
            0,
            "换根失败后 pending 防抖写必须照常执行(不得取消后不补排)"
        )
    }

    /// persistSettings(立即写盘)失败不得取消 pending 的防抖写:与 updateRootPath
    /// 同口径——旧实现在 save 之前 cancel,写盘失败时防抖写被取消且无人重排,
    /// 内存与 settings.json 背离直到下一次成功写盘。
    /// 判别点:失败路径下防抖任务仍活着,到点 flush 失败进入重试,flushRetryCount 变正。
    func test_persistSettingsFailureKeepsPendingDebouncedWrite() async throws {
        try XCTSkipIf(geteuid() == 0, "root 身份下只读目录不生效")
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SettingsStore(
            fileStore: JSONFileStore(rootDirectory: root),
            flushRetryBaseSeconds: 0
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        store.updateLastSelectedRoute("workplaces") // 500ms 防抖后才落盘
        XCTAssertThrowsError(try store.updateAppearanceMode(.dark), "前置:立即写盘失败")
        XCTAssertEqual(store.flushRetryCount, 0, "前置:尚未有任何 flush")

        let deadline = Date().timeIntervalSince1970 + 2
        while Date().timeIntervalSince1970 < deadline, store.flushRetryCount == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertGreaterThan(
            store.flushRetryCount,
            0,
            "立即写盘失败后 pending 防抖写必须照常执行(不得取消后不补排)"
        )
    }

    func test_existingSettingsWithLegacyEditorCommandPreservesRootPath() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)

        let legacyJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","editorCommand":"code"}"#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyJSON.write(to: root.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let store = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(store.settings.workplaceRootPath, "/Users/demo/Workplaces")
    }

    /// 写盘失败后的重试必须有上限:旧实现的重试任务醒来先清句柄再 flush,
    /// 失败后 scheduleFlushRetry 的 guard 恒为真 → 每 5s 一次同步写加一条 error
    /// 日志、永不收敛。这里用只读目录让写必然失败、注入 0s 退避,断言计数封顶后不再增长。
    func test_flushRetryStopsAfterMaxAttemptsWhenSaveKeepsFailing() async throws {
        // root 身份下只读目录不生效,跳过(同换根回滚用例)。
        try XCTSkipIf(geteuid() == 0, "root 身份下只读目录不生效")
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SettingsStore(
            fileStore: JSONFileStore(rootDirectory: root),
            flushRetryBaseSeconds: 0
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        store.flushSettings()

        XCTAssertGreaterThan(store.flushRetryCount, 0, "写失败必须进入重试")
        let deadline = Date().timeIntervalSince1970 + 2
        while Date().timeIntervalSince1970 < deadline,
              store.flushRetryCount < SettingsStore.maxFlushRetryCount {
            try await Task.sleep(for: .milliseconds(20))
        }
        let settled = store.flushRetryCount
        XCTAssertEqual(settled, SettingsStore.maxFlushRetryCount, "持续失败时重试应跑满封顶次数")

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.flushRetryCount, settled, "达到上限后不得继续重试(不是无限循环)")
    }

    /// 换根直接写盘成功必须归零重试预算:此前只在 persistSettings/flushSettings 归零,
    /// 若重试已封顶(=5),换根成功后下一次 flush 失败会立刻放弃、零重试。
    func test_updateRootPathResetsFlushRetryCountAfterSuccess() async throws {
        try XCTSkipIf(geteuid() == 0, "root 身份下只读目录不生效")
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore, flushRetryBaseSeconds: 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        store.flushSettings()
        XCTAssertGreaterThan(store.flushRetryCount, 0, "写失败必须进入重试")
        let deadline = Date().timeIntervalSince1970 + 2
        while Date().timeIntervalSince1970 < deadline,
              store.flushRetryCount < SettingsStore.maxFlushRetryCount {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.flushRetryCount, SettingsStore.maxFlushRetryCount, "前置:重试已封顶")
        // 封顶前最后一次 0s 重试可能仍在途,等它落地(此时目录仍只读,只会失败)。
        try await Task.sleep(for: .milliseconds(100))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        try store.updateRootPath(
            "/Users/demo/NewWorkplaces",
            rebasingWorkplaceStore: WorkplaceStore(fileStore: fileStore)
        )

        XCTAssertEqual(store.flushRetryCount, 0, "换根成功必须重置重试预算,后续失败仍有完整重试次数")
    }
}

