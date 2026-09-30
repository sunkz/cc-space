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

    /// AI 配置保存:API Key 明文随配置落盘,新 Store 读回完整配置(所见即所存)。
    func test_updateAISettingsPersistsAPIKeyInFileAndReloads() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)
        let aiSettings = AppSettings.AISettings(
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-test",
            apiKey: "sk-secret-123"
        )

        try firstStore.updateAISettings(aiSettings)

        let rawJSON = try String(
            contentsOf: root.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(rawJSON.contains("\"apiKey\""), "API Key 字段必须落盘")
        XCTAssertTrue(rawJSON.contains("sk-secret-123"), "钥匙串功能已移除,Key 以明文落盘")

        let secondStore = SettingsStore(fileStore: fileStore)
        let loaded = try XCTUnwrap(secondStore.settings.aiSettings)
        XCTAssertEqual(loaded.baseURL, aiSettings.baseURL)
        XCTAssertEqual(loaded.modelName, aiSettings.modelName)
        XCTAssertEqual(loaded.apiKey, "sk-secret-123")
    }

    func test_clearAISettingsPersistsNil() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)
        try firstStore.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test", apiKey: "sk-x")
        )

        try firstStore.updateAISettings(nil)

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertNil(secondStore.settings.aiSettings)
    }

    /// 启动(构造)只读不写:带明文 Key 的旧文件原样保留,
    /// 不再有钥匙串迁移及其重写文件的副作用。
    func test_constructionLoadsPlaintextAPIKeyWithoutRewritingFile() throws {
        let root = makeTestRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyJSON = """
        {"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm","apiKey":"legacy-secret"}}
        """
        let settingsURL = root.appendingPathComponent("settings.json")
        try legacyJSON.write(to: settingsURL, atomically: true, encoding: .utf8)

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.settings.aiSettings?.apiKey, "legacy-secret", "构造读入完整 Key")
        XCTAssertEqual(
            try String(contentsOf: settingsURL, encoding: .utf8),
            legacyJSON,
            "构造不得改写 settings.json(启动迁移已随钥匙串移除)"
        )
    }

    /// 所见即所存:输入框(回显自已存值)清空后保存,已存 Key 随之删除。
    /// 钥匙串时代的"空串回读保护"已随钥匙串一并移除——本地文件回显不存在
    /// "读失败折叠成空串"的歧义,清空输入框是显式动作。
    func test_updateAISettingsClearsStoredAPIKeyWhenInputEmptied() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore)
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "glm", apiKey: "sk-secret-123")
        )

        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v2", modelName: "glm-2", apiKey: "")
        )

        XCTAssertEqual(store.settings.aiSettings?.apiKey, "", "清空输入框后保存即删除已存 Key")
        XCTAssertEqual(store.settings.aiSettings?.baseURL, "https://api.example.com/v2", "其余配置照常保存")
        let reloaded = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.settings.aiSettings?.apiKey, "", "删除结果落盘")
    }

    /// 仅清除密钥、保留配置:换 Key / 改用本地服务的正规入口。
    func test_clearStoredAPIKeyClearsKeyAndKeepsConfig() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore)
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test", apiKey: "sk-x")
        )

        try store.clearStoredAPIKey()

        let ai = try XCTUnwrap(store.settings.aiSettings)
        XCTAssertEqual(ai.baseURL, "https://api.example.com/v1", "Base URL 保留")
        XCTAssertEqual(ai.modelName, "gpt-test", "模型名保留")
        XCTAssertEqual(ai.apiKey, "")

        // 落盘可复读:重新加载后配置仍在、Key 仍空。
        let reloaded = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.settings.aiSettings?.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(reloaded.settings.aiSettings?.apiKey, "")
    }

    /// 无 AI 配置时是 no-op:没有可清的 Key。
    func test_clearStoredAPIKeyIsNoopWithoutAIConfig() throws {
        let root = makeTestRootURL()
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore)

        XCTAssertNoThrow(try store.clearStoredAPIKey())
        XCTAssertNil(store.settings.aiSettings)
    }

    func test_decodingSettingsWithoutAISettingsYieldsNil() throws {
        let legacyJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces"}"#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(settings.aiSettings)
        XCTAssertEqual(settings.workplaceRootPath, "/Users/demo/Workplaces")
    }

    func test_decodingAISettingsWithoutAPIKeyKeepsOtherSettings() throws {
        // AISettings 手写解码:字段缺失降级为默认值,而不是把整个 settings.json 判为损坏。
        let legacyJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"gpt-test"}}"#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(settings.workplaceRootPath, "/Users/demo/Workplaces")
        XCTAssertEqual(settings.aiSettings?.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(settings.aiSettings?.modelName, "gpt-test")
        XCTAssertEqual(settings.aiSettings?.apiKey, "")
    }

    func test_decodingAISettingsWithUnknownFutureFieldIsIgnored() throws {
        let futureJSON = #"{"workplaceRootPath":"/tmp","aiSettings":{"baseURL":"https://a.com","modelName":"m","apiKey":"k","futureField":1}}"#

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(futureJSON.utf8)
        )

        XCTAssertEqual(settings.aiSettings?.apiKey, "k")
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

