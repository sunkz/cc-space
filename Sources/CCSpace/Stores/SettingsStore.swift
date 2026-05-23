import Foundation
import os

private let settingsStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "SettingsStore"
)

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let fileStore: JSONFileStore

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        do {
            self.settings = try fileStore.loadIfPresent(
                AppSettings.self,
                from: "settings.json",
                default: AppSettings(workplaceRootPath: "")
            )
        } catch {
            settingsStoreLog.error("event=load_settings_failed reason=\(error.localizedDescription)")
            self.settings = AppSettings(workplaceRootPath: "")
        }
    }

    private func persistSettings(_ newSettings: AppSettings) throws {
        try fileStore.save(newSettings, as: "settings.json")
        settings = newSettings
    }

    func updateRootPath(_ path: String) throws {
        var updatedSettings = settings
        updatedSettings.workplaceRootPath = path
        try persistSettings(updatedSettings)
    }

    func saveRootPathAndReturnErrorMessage(_ path: String) -> String? {
        do {
            try updateRootPath(path)
            return nil
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    func updatePreferredOpenActionID(_ actionID: String?) throws {
        var updatedSettings = settings
        updatedSettings.preferredOpenActionID = actionID
        try persistSettings(updatedSettings)
    }

    func updateHasCompletedOnboarding(_ value: Bool) throws {
        var updatedSettings = settings
        updatedSettings.hasCompletedOnboarding = value
        try persistSettings(updatedSettings)
    }
}
