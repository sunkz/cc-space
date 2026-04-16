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

        try firstStore.updateRootPath("/tmp/workplaces")

        let secondStore = SettingsStore(fileStore: fileStore)
        XCTAssertEqual(secondStore.settings.workplaceRootPath, "/tmp/workplaces")
    }

    func test_encodingSettingsOnlyPersistsWorkplaceRootPath() throws {
        let settings = AppSettings(workplaceRootPath: "/tmp/workplaces")

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("workplaceRootPath"))
        XCTAssertFalse(json.contains("editorCommand"))
    }

    func test_saveRootPathErrorMessageWhenPersistFails() throws {
        let rootFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: rootFileURL, options: .atomic)

        let store = SettingsStore(fileStore: JSONFileStore(rootDirectory: rootFileURL))
        let errorMessage = store.saveRootPathAndReturnErrorMessage("/tmp/workplaces")

        XCTAssertNotNil(errorMessage)
        XCTAssertTrue(errorMessage?.contains("保存失败") == true)
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
