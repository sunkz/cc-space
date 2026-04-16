import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let fileStore: JSONFileStore

    init(fileStore: JSONFileStore) {
        self.fileStore = fileStore
        self.settings =
            (try? fileStore.loadIfPresent(
                AppSettings.self,
                from: "settings.json",
                default: AppSettings(workplaceRootPath: "")
            )) ?? AppSettings(workplaceRootPath: "")
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
}
