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

    func test_updateAISettingsPersistsAndLoadsFromNewStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)
        let aiSettings = AppSettings.AISettings(
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-test"
        )

        try firstStore.updateAISettings(aiSettings)

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(secondStore.settings.aiSettings, aiSettings)
    }

    func test_clearAISettingsPersistsNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = JSONFileStore(rootDirectory: root)
        let firstStore = SettingsStore(fileStore: fileStore)
        try firstStore.updateAISettings(
            .init(baseURL: "https://api.example.com/v1", modelName: "gpt-test")
        )

        try firstStore.updateAISettings(nil)

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertNil(secondStore.settings.aiSettings)
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

        // 越过防抖窗口后,落盘内容必须仍是新根。
        try await Task.sleep(for: .milliseconds(800))
        let reloaded = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(reloaded.settings.workplaceRootPath, "/Users/demo/NewWorkplaces")
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
}
