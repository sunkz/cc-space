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
    private var debouncedSettingsWriteTask: Task<Void, Never>?

    /// 本次启动 settings.json 是否损坏并被重置为默认值。
    /// 上游 View 可据此提示用户配置已重置(而不是让用户以为自己没设置过)。
    private(set) var didRecoverFromCorruptFile = false

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
            fileStore.preserveCorruptFile(named: "settings.json")
            self.settings = AppSettings(workplaceRootPath: "")
            didRecoverFromCorruptFile = true
        }
    }

    private func persistSettings(_ newSettings: AppSettings) throws {
        cancelDebouncedSettingsWrite()
        try fileStore.save(newSettings, as: "settings.json")
        settings = newSettings
    }

    /// 防抖持久化:内存立即生效,写盘延后合并。
    ///
    /// 侧栏快速切换工作区 / 路由会连续触发 `lastSelected*` 写入,每次都同步走一遍
    /// "建暂存目录 + remove + move"会造成主线程 I/O 尖峰与 SSD 写放大。这类纯
    /// "记忆上次位置"的字段丢一次无所谓,适合防抖;换根目录等强一致操作仍走立即写盘。
    private func persistSettingsDebounced(_ newSettings: AppSettings) {
        settings = newSettings
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            // 任务可能已被后续写入/立即写盘取代(cancel 与 sleep 恢复存在竞态窗口):
            // 取消后不得再落盘,否则会用捕获的旧快照覆写更新的 settings.json。
            guard Task.isCancelled == false else { return }
            // 写当前最新快照而非闭包捕获值:即使本任务仍是 pending,内存里的
            // `settings` 只会更新不会回退,写最新值更安全。
            let snapshot = self.settings
            self.debouncedSettingsWriteTask = nil
            do {
                try self.fileStore.save(snapshot, as: "settings.json")
            } catch {
                settingsStoreLog.error("event=persist_settings_debounced_failed reason=\(error.localizedDescription)")
            }
        }
    }

    private func cancelDebouncedSettingsWrite() {
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = nil
    }

    /// 把防抖窗口内未落盘的改动立即写入(退出 / 场景切换时调用)。
    func flushSettings() {
        guard let pending = debouncedSettingsWriteTask else { return }
        debouncedSettingsWriteTask = nil
        pending.cancel()
        do {
            try fileStore.save(settings, as: "settings.json")
        } catch {
            settingsStoreLog.error("event=flush_settings_failed reason=\(error.localizedDescription)")
        }
    }

    /// 换根目录,并把已有工作区路径迁移到新根下——两者**一次原子提交**。
    ///
    /// 这是**唯一**允许生产调用的换根入口:此前还存在一个不做迁移的单参数重载,
    /// 二者同名极易走错;走错那个的后果(见下)是工作区被磁盘刷新误删,因此已删除。
    ///
    /// 此前的两步写盘(先 rebase 工作区、再写 settings.json)不原子:第二步失败时
    /// 工作区记录已指向新根而 settings 仍是旧根,下次磁盘刷新会把不在旧根下的
    /// 工作区判为 missing 永久删除。这里利用 JSONFileStore.save(documents) 把
    /// settings.json 与 workplaces/sync-states 合并落盘,任一失败整体回滚。
    /// 注意:要求两个 Store 共用同一数据目录(生产环境由 RootSplitView 注入同一 fileStore)。
    ///
    /// 返回实际改写路径的工作区条数,供 UI 提示"几个工作区需要手动搬目录"。
    @discardableResult
    func updateRootPath(_ path: String, rebasingWorkplaceStore workplaceStore: WorkplaceStore) throws -> Int {
        // 必须先取消防抖写入:pending 的防抖任务若稍后用旧快照落盘,
        // workplaceRootPath 会回到旧根,而 workplaces/sync-states 已 rebase 到新根,
        // 下次磁盘刷新会把"不在旧根下"的工作区判为 missing 永久删除。
        cancelDebouncedSettingsWrite()

        let plan = workplaceStore.rebasePlan(
            fromRoot: settings.workplaceRootPath,
            toRoot: path
        )

        var updatedSettings = settings
        updatedSettings.workplaceRootPath = path
        var documents = [try fileStore.document(for: updatedSettings, as: "settings.json")]
        if let plan {
            documents += try workplaceStore.persistenceDocuments(
                workplaces: plan.workplaces,
                syncStates: plan.syncStates
            )
        }
        try fileStore.save(documents)

        settings = updatedSettings
        if let plan {
            workplaceStore.applyPersistedState(
                workplaces: plan.workplaces,
                syncStates: plan.syncStates
            )
        }
        return plan?.rebasedCount ?? 0
    }

    /// `saveRootPathAndReturnErrorMessage` 的换根迁移版:与工作区路径迁移原子提交。
    func saveRootPathAndReturnErrorMessage(
        _ path: String,
        rebasingWorkplaceStore workplaceStore: WorkplaceStore
    ) -> String? {
        do {
            try updateRootPath(path, rebasingWorkplaceStore: workplaceStore)
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

    func updateAppearanceMode(_ mode: AppSettings.AppearanceMode) throws {
        var updatedSettings = settings
        updatedSettings.appearanceMode = mode
        try persistSettings(updatedSettings)
    }

    /// 保存 AI 服务配置;传 nil 表示清除配置。
    func updateAISettings(_ aiSettings: AppSettings.AISettings?) throws {
        var updatedSettings = settings
        updatedSettings.aiSettings = aiSettings
        try persistSettings(updatedSettings)
    }

    func updateHasCompletedOnboarding(_ value: Bool) throws {
        var updatedSettings = settings
        updatedSettings.hasCompletedOnboarding = value
        try persistSettings(updatedSettings)
    }

    /// 仅用于"下次启动恢复到哪",高频且可容忍丢失一次,走防抖写盘。
    func updateLastSelectedRoute(_ route: String?) {
        var updatedSettings = settings
        updatedSettings.lastSelectedRoute = route
        persistSettingsDebounced(updatedSettings)
    }

    func updateLastSelectedWorkplaceID(_ workplaceID: String?) {
        var updatedSettings = settings
        updatedSettings.lastSelectedWorkplaceID = workplaceID
        persistSettingsDebounced(updatedSettings)
    }
}
