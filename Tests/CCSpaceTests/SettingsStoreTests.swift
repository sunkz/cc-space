import XCTest
@testable import CCSpace

@MainActor
final class SettingsStoreTests: XCTestCase {
    func test_defaultsToEmptyRootPathWhenNoSettingsFile() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root))

        XCTAssertEqual(store.settings.workplaceRootPath, "")
    }

    func test_updateRootPathPersistsAndLoadsFromNewStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

    func test_updateAISettingsStoresKeyInKeychainAndStripsPlaintextFromFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let keychain = InMemoryAPIKeyStore()
        let firstStore = SettingsStore(fileStore: fileStore, keychain: keychain)
        let aiSettings = AppSettings.AISettings(
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-test",
            apiKey: "sk-secret-123"
        )

        try firstStore.updateAISettings(aiSettings)

        // 密钥进钥匙串;settings.json 里绝不出现明文。
        XCTAssertEqual(keychain.storedKey, "sk-secret-123")
        let rawJSON = try String(
            contentsOf: root.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawJSON.contains("sk-secret-123"), "API Key 不得再明文落盘")
        XCTAssertFalse(rawJSON.contains("\"apiKey\""))

        // 新 Store 构造完成即从钥匙串回填内存,消费方(设置页首帧读
        // settings.aiSettings.apiKey)不依赖任何显式迁移调用。
        let secondStore = SettingsStore(fileStore: fileStore, keychain: keychain)
        let loaded = try XCTUnwrap(secondStore.settings.aiSettings)
        XCTAssertEqual(loaded.baseURL, aiSettings.baseURL)
        XCTAssertEqual(loaded.modelName, aiSettings.modelName)
        XCTAssertEqual(loaded.apiKey, "sk-secret-123")
        XCTAssertTrue(loaded.apiKeyManagedExternally)
    }

    func test_clearAISettingsPersistsNilAndDeletesKeychainItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let keychain = InMemoryAPIKeyStore()
        let firstStore = SettingsStore(fileStore: fileStore, keychain: keychain)
        try firstStore.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test", apiKey: "sk-x")
        )

        try firstStore.updateAISettings(nil)

        XCTAssertNil(keychain.storedKey, "清除配置必须连钥匙串条目一起删除")
        let secondStore = SettingsStore(fileStore: fileStore, keychain: keychain)
        XCTAssertNil(secondStore.settings.aiSettings)
    }

    /// 旧版本明文 settings.json → 构造时一次性迁入钥匙串并重写文件。
    /// 迁移必须在**构造路径**内完成(见 SettingsStore.init):设置页首帧按
    /// `aiSettings.apiKey` 给 `@State` 赋初值,晚于首帧(如 onAppear)的迁移
    /// 来不及回填,输入框会永远停在空串。
    func test_legacyPlaintextAPIKeyMigratesToKeychainOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyJSON = """
        {"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm","apiKey":"legacy-secret"}}
        """
        let settingsURL = root.appendingPathComponent("settings.json")
        try legacyJSON.write(to: settingsURL, atomically: true, encoding: .utf8)

        let keychain = InMemoryAPIKeyStore()
        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root), keychain: keychain)

        // 构造完成即迁移:不等组合根的显式调用,任何 body 期读配置的消费方都拿到完整 Key。
        XCTAssertEqual(keychain.storedKey, "legacy-secret", "构造必须完成钥匙串迁移")
        XCTAssertEqual(store.settings.aiSettings?.apiKey, "legacy-secret", "迁入后内存仍持有完整配置")
        XCTAssertFalse(
            try String(contentsOf: settingsURL, encoding: .utf8).contains("legacy-secret"),
            "构造后的重写不得保留明文"
        )

        // 幂等:重复调用是 no-op,文件仍无明文。
        store.performLaunchMigrationIfNeeded()
        XCTAssertEqual(keychain.storedKey, "legacy-secret")
        XCTAssertFalse(
            try String(contentsOf: settingsURL, encoding: .utf8).contains("legacy-secret"),
            "重复调用不得把明文写回文件"
        )
    }

    /// R2 回归锁:迁移挪到 onAppear 后,`AISettingsSection` 首帧(`@State initialValue`)
    /// 早于回填捕获空 Key;用户只改 Base URL/模型名就保存 → `storeAPIKey("")`
    /// (空串语义是删除)把钥匙串里的真 Key 静默删掉。构造完成时 Key 必须已回填,
    /// 随后的保存不得丢钥匙串条目。
    func test_constructionBackfillsManagedAPIKeyBeforeAnyConsumerReadsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 托管态:settings.json 无明文 apiKey 字段,真 Key 只在钥匙串。
        let managedJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm"}}"#
        try managedJSON.write(
            to: root.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
        let keychain = InMemoryAPIKeyStore()
        try keychain.storeAPIKey("sk-secret-123")

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root), keychain: keychain)

        // 消费方首帧读到的就是完整 Key(等价于 AISettingsSection 的 @State 初值)。
        let echoedKey = try XCTUnwrap(store.settings.aiSettings?.apiKey)
        XCTAssertEqual(echoedKey, "sk-secret-123", "构造完成即回填,不等组合根显式迁移")

        // 模拟设置页保存:Key 输入框回显首帧取到的值(用户未改 Key)。
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v2", modelName: "glm-2", apiKey: echoedKey)
        )

        XCTAssertEqual(
            keychain.storedKey,
            "sk-secret-123",
            "保存不得把钥匙串里的真 Key 覆盖成空串(空串语义是删除)"
        )
    }

    /// 钥匙串不可用时降级:明文照旧落盘不丢配置,且保留降级标记供后续收敛。
    func test_keychainFailureFallsBackToPlaintextPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let store = SettingsStore(fileStore: fileStore, keychain: FailingAPIKeyStore())

        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "glm", apiKey: "sk-degraded")
        )

        XCTAssertFalse(store.apiKeyStoredInKeychain)
        let rawJSON = try String(
            contentsOf: root.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(rawJSON.contains("sk-degraded"), "钥匙串失败时明文降级落盘,不能静默丢密钥")
    }

    /// 第三轮 R2 同型的另一条丢 Key 路径:钥匙串**读**失败(锁屏/ACL 拒绝)时
    /// `readAPIKey` 与"无条目"一样返回 nil,回填把空串折叠进内存,而
    /// `apiKeyStoredInKeychain` 仍是 true(无降级横幅)。用户只改 Base URL 保存,
    /// 空串落钥匙串的删除语义会把真 Key 永久删掉。保存前必须回读确认:
    /// 读不到就跳过钥匙串写入,真 Key 必须还在。
    func test_updateAISettingsDoesNotDeleteKeyWhenKeychainReadFoldedToEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let managedJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm"}}"#
        try managedJSON.write(
            to: root.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
        let keychain = UnreadWhilePresentAPIKeyStore(storedKey: "sk-secret-123", isReadable: false)

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root), keychain: keychain)

        // 前置:读失败折叠成空串,且降级标记仍为 true——界面上没有任何横幅能提醒用户。
        XCTAssertEqual(store.settings.aiSettings?.apiKey, "")
        XCTAssertTrue(store.apiKeyStoredInKeychain)

        // 模拟设置页保存:Key 输入框回显的是折叠出来的空串,用户只改了 Base URL。
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v2", modelName: "glm-2", apiKey: "")
        )

        XCTAssertEqual(keychain.storedKey, "sk-secret-123", "读不到时不得按空串删除真 Key")
        XCTAssertEqual(store.settings.aiSettings?.baseURL, "https://api.example.com/v2", "其余配置照常保存")
        XCTAssertTrue(store.settings.aiSettings?.apiKeyManagedExternally == true, "文件里不落明文")
    }

    /// 读失败只是一过性(启动时读不到、保存时已恢复):空串回显被回读纠正,
    /// 保存后内存与钥匙串同构,消费方按完整配置读。
    func test_updateAISettingsBackfillsKeyWhenReadRecoversBeforeSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let managedJSON = #"{"workplaceRootPath":"/Users/demo/Workplaces","aiSettings":{"baseURL":"https://api.example.com/v1","modelName":"glm"}}"#
        try managedJSON.write(
            to: root.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
        let keychain = UnreadWhilePresentAPIKeyStore(storedKey: "sk-secret-123", isReadable: false)
        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: root), keychain: keychain)
        XCTAssertEqual(store.settings.aiSettings?.apiKey, "", "前置:启动回读失败折叠成空串")

        keychain.isReadable = true
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v2", modelName: "glm-2", apiKey: "")
        )

        XCTAssertEqual(keychain.storedKey, "sk-secret-123")
        XCTAssertEqual(store.settings.aiSettings?.apiKey, "sk-secret-123", "回读成功时按真 Key 保存并回填内存")
    }

    /// 清除配置时钥匙串删除失败必须中止并可见报错:照常落盘 nil 会让
    /// apiKeyStoredInKeychain 与真实态背离,且旧 Key 仍躺在钥匙串里——用户随后
    /// 重新配置且 Key 留空时,回读保护会把旧 Key 无声复活。
    func test_clearAISettingsThrowsAndKeepsStateWhenKeychainDeleteFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let keychain = DeleteFailingAPIKeyStore()
        let store = SettingsStore(fileStore: fileStore, keychain: keychain)
        try store.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test", apiKey: "sk-x")
        )

        XCTAssertThrowsError(try store.updateAISettings(nil)) { error in
            guard case SettingsStoreError.keychainDeleteFailed = error else {
                return XCTFail("应为 keychainDeleteFailed,实际:\(error)")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("清除 AI 配置失败"),
                "面向用户文案须为简体中文: \(error.localizedDescription)"
            )
        }

        // 状态保持真实:配置仍在、Key 仍在钥匙串——不出现"文件已清除但钥匙串残留"的谎报态。
        XCTAssertEqual(keychain.storedKey, "sk-x")
        XCTAssertEqual(store.settings.aiSettings?.apiKey, "sk-x")
        XCTAssertTrue(store.apiKeyStoredInKeychain)
        let reloaded = SettingsStore(fileStore: fileStore, keychain: DeleteFailingAPIKeyStore())
        XCTAssertNotNil(reloaded.settings.aiSettings, "清除失败不得落盘 nil 配置")
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
        let rootFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

// MARK: - 测试用钥匙串替身

/// 内存钥匙串:测试不得触碰真实 Security 框架(避免在 CI/开发机留真实条目)。
final class InMemoryAPIKeyStore: APIKeySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _storedKey: String?

    var storedKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return _storedKey
    }

    func readAPIKey() -> String? { storedKey }

    func storeAPIKey(_ apiKey: String) throws {
        lock.lock()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _storedKey = trimmed.isEmpty ? nil : trimmed
        lock.unlock()
    }
}

struct FailingAPIKeyStore: APIKeySecretStore {
    func readAPIKey() -> String? { nil }
    func storeAPIKey(_ apiKey: String) throws {
        throw APIKeySecretStoreError.unavailable(reason: "test")
    }
}

/// 存储正常、仅"空串=删除"失败的钥匙串替身:复现清除配置时 SecItemDelete 出错。
final class DeleteFailingAPIKeyStore: APIKeySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _storedKey: String?

    var storedKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return _storedKey
    }

    func readAPIKey() -> String? { storedKey }

    func storeAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw APIKeySecretStoreError.unavailable(reason: "删除旧条目失败(status -1)")
        }
        lock.lock()
        _storedKey = trimmed
        lock.unlock()
    }
}

/// 条目在、但读被拒的钥匙串(锁屏/ACL 拒绝场景):`readAPIKey` 返回 nil,
/// 与"无条目"不可区分——正是把空串折叠进内存的根因。
final class UnreadWhilePresentAPIKeyStore: APIKeySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _storedKey: String?
    private var _isReadable: Bool

    init(storedKey: String?, isReadable: Bool) {
        self._storedKey = storedKey
        self._isReadable = isReadable
    }

    var storedKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return _storedKey
    }

    var isReadable: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isReadable
        }
        set {
            lock.lock()
            _isReadable = newValue
            lock.unlock()
        }
    }

    func readAPIKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _isReadable ? _storedKey : nil
    }

    func storeAPIKey(_ apiKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _storedKey = trimmed.isEmpty ? nil : trimmed
    }
}
