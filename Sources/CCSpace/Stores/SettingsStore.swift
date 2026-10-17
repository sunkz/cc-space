import Foundation
import os

private let settingsStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "SettingsStore"
)

enum SettingsStoreError: LocalizedError, Equatable {
    case crossStoreRootMismatch

    var errorDescription: String? {
        switch self {
        case .crossStoreRootMismatch:
            return "内部状态异常：设置与工作区的数据目录不一致，已取消本次操作"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let fileStore: JSONFileStore
    private var debouncedSettingsWriteTask: Task<Void, Never>?
    /// 写盘失败的重试次数:成功或用户下一次变更归零,封顶见 `maxFlushRetryCount`。
    private(set) var flushRetryCount = 0
    /// 重试上限:超过即放弃,避免"固定间隔同步写 + 一条 error 日志"永不收敛。
    static let maxFlushRetryCount = 5
    private let flushRetryBaseSeconds: Int

    /// 本次启动 settings.json 是否损坏并被重置为默认值。
    /// 上游 View 据此提示用户配置已重置;任一 Store 处于恢复态时调用方须跳过破坏性对账。
    private(set) var didRecoverFromCorruptFile = false

    init(
        fileStore: JSONFileStore,
        flushRetryBaseSeconds: Int = 5
    ) {
        self.fileStore = fileStore
        self.flushRetryBaseSeconds = flushRetryBaseSeconds
        do {
            self.settings = try fileStore.loadIfPresent(
                AppSettings.self,
                from: "settings.json",
                default: AppSettings(workplaceRootPath: "")
            )
        } catch {
            settingsStoreLog.error("event=load_settings_failed reason=\(error.localizedDescription, privacy: .public)")
            fileStore.preserveCorruptFile(named: "settings.json")
            self.settings = AppSettings(workplaceRootPath: "")
            didRecoverFromCorruptFile = true
        }
    }

    /// 内存先行、同步写盘:写盘成功才改内存,失败抛给调用方回滚。刻意保持同步语义——换根的跨文件
    /// 原子提交与防抖重试都依赖"写盘与状态更新在同一主线程顺序发生",改到后台队列会牵动失败回滚时序。
    private func persistSettings(_ newSettings: AppSettings) throws {
        // 取消防抖任务放在 save 成功之后:写盘失败时 pending 的防抖写照常到点执行并重试兜底,
        // 取消后不补排会造成内存与文件背离。本函数 save 与赋值之间无 await,任务不会中途跑掉。
        try fileStore.save(newSettings, as: "settings.json")
        cancelDebouncedSettingsWrite()
        settings = newSettings
        flushRetryCount = 0
    }

    /// 防抖持久化:内存立即生效,写盘延后合并。侧栏快速切换会连续触发 `lastSelected*` 写入,
    /// 每次同步"建暂存目录 + remove + move"会造成主线程 I/O 尖峰;这类纯"记忆上次位置"的字段丢一次无所谓。
    private func persistSettingsDebounced(_ newSettings: AppSettings) {
        settings = newSettings
        flushRetryCount = 0
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            // 竞态窗口:cancel 与 sleep 恢复之间任务可能已被后续写入/立即写盘取代。
            // 取消后不得再落盘,否则会用捕获的旧快照覆写更新的 settings.json。
            guard Task.isCancelled == false else { return }
            self.flushSettings()
        }
    }

    private func cancelDebouncedSettingsWrite() {
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = nil
    }

    /// 无条件把当前内存快照落盘(防抖到点 / 退出 / 场景切换时调用)。
    /// 不能以"是否存在 pending 任务"为前置:重试任务到点会先清空句柄再进来,提前 return 会让重试空转。
    func flushSettings() {
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = nil
        do {
            try fileStore.save(settings, as: "settings.json")
            flushRetryCount = 0
        } catch {
            // reason 不标 .public 会被脱敏成 <private>,写盘失败原因必须可读。
            settingsStoreLog.error("event=flush_settings_failed reason=\(error.localizedDescription, privacy: .public)")
            scheduleFlushRetry()
        }
    }

    /// 写盘失败后按 base×次数 退避重试(5s→10s→15s…),最多 `maxFlushRetryCount` 次:不重试则内存与
    /// 文件无限期背离,无限重试则每 5s 一次同步写加一条 error 日志永不收敛。变更/写成功会把计数归零。
    private func scheduleFlushRetry() {
        guard debouncedSettingsWriteTask == nil else { return }
        guard flushRetryCount < Self.maxFlushRetryCount else {
            settingsStoreLog.error("event=flush_retry_abandoned attempts=\(self.flushRetryCount, privacy: .public)")
            return
        }
        flushRetryCount += 1
        let delaySeconds = flushRetryBaseSeconds * flushRetryCount
        debouncedSettingsWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            self?.debouncedSettingsWriteTask = nil
            self?.flushSettings()
        }
    }

    /// 换根并把已有工作区路径迁移到新根下——两者**一次原子提交**,任一失败整体回滚;分开写时第二步失败
    /// 会留下"记录指新根、设置仍是旧根",下次磁盘刷新把不在旧根下的工作区判为 missing 永久删除。
    @discardableResult
    func updateRootPath(_ path: String, rebasingWorkplaceStore workplaceStore: WorkplaceStore) throws -> Int {
        // 跨 Store 原子提交的前提是共用同一数据目录:注入分叉会让内存与磁盘静默背离,故提交前拦截。
        guard fileStore.rootDirectory.standardizedFileURL
            == workplaceStore.rootDirectoryForCrossStoreCheck.standardizedFileURL else {
            throw SettingsStoreError.crossStoreRootMismatch
        }

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

        // 落盘成功后才取消 pending 防抖写:失败路径保留该任务(内存仍是旧值,防抖照落地),避免
        // "取消后不补排"造成内存与 settings.json 背离。本函数到此无 await,任务不会中途跑掉。
        cancelDebouncedSettingsWrite()

        settings = updatedSettings
        // 换根写盘成功同样要归零重试预算:否则此前已封顶时,换根后首次 flush 失败会立刻放弃、零重试。
        flushRetryCount = 0
        if let plan {
            workplaceStore.applyPersistedState(
                workplaces: plan.workplaces,
                syncStates: plan.syncStates
            )
        }
        return plan?.rebasedCount ?? 0
    }

    func saveRootPathAndReturnErrorMessage(
        _ path: String,
        rebasingWorkplaceStore workplaceStore: WorkplaceStore
    ) -> String? {
        do {
            try updateRootPath(path, rebasingWorkplaceStore: workplaceStore)
            return nil
        } catch {
            // 必须经 UserFacingError 收口:裸 localizedDescription 会把系统英文原文打进设置横幅。
            return "保存失败：\(UserFacingError.message(for: error))"
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
