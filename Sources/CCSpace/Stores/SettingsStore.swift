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
    /// private(set) 仅为测试可读(断言重试有界)。
    private(set) var flushRetryCount = 0
    /// 重试上限:超过即放弃,避免"固定间隔同步写 + 一条 error 日志"永不收敛。
    static let maxFlushRetryCount = 5
    /// 重试基础间隔(秒),退避按 base×次数 线性增长(5s→10s→15s…);默认 5,
    /// 仅测试注入更小值以缩短等待。
    private let flushRetryBaseSeconds: Int

    /// 本次启动 settings.json 是否损坏并被重置为默认值。
    /// 上游 View 可据此提示用户配置已重置(而不是让用户以为自己没设置过)。
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

    /// 内存先行、同步写盘:写盘成功才改内存,失败抛给调用方回滚。
    /// 已知代价:每次写都是一次同步磁盘 I/O,数据目录在外置盘/网盘上时可能阻塞
    /// 主线程数秒。刻意保持同步语义——换根的跨文件原子提交与防抖重试都依赖
    /// "写盘与状态更新在同一主线程上顺序发生",改成后台队列会牵动失败回滚时序。
    private func persistSettings(_ newSettings: AppSettings) throws {
        // 取消防抖任务放在 save 成功之后(与 updateRootPath 同口径):写盘失败时
        // pending 的防抖写照常到点执行并重试兜底,取消后不补排会造成内存与文件
        // 背离直到下一次成功写盘。本函数 save 与赋值之间无 await,任务不会中途跑掉。
        try fileStore.save(newSettings, as: "settings.json")
        cancelDebouncedSettingsWrite()
        settings = newSettings
        flushRetryCount = 0
    }

    /// 防抖持久化:内存立即生效,写盘延后合并。
    ///
    /// 侧栏快速切换工作区 / 路由会连续触发 `lastSelected*` 写入,每次都同步走一遍
    /// "建暂存目录 + remove + move"会造成主线程 I/O 尖峰与 SSD 写放大。这类纯
    /// "记忆上次位置"的字段丢一次无所谓,适合防抖;换根目录等强一致操作仍走立即写盘。
    private func persistSettingsDebounced(_ newSettings: AppSettings) {
        settings = newSettings
        // 用户变更:失败重试的退避从头计起。
        flushRetryCount = 0
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            // 任务可能已被后续写入/立即写盘取代(cancel 与 sleep 恢复存在竞态窗口):
            // 取消后不得再落盘,否则会用捕获的旧快照覆写更新的 settings.json。
            guard Task.isCancelled == false else { return }
            // 交给 flushSettings 写当前最新快照:即使本任务仍是 pending,内存里的
            // `settings` 只会更新不会回退,写最新值更安全;写盘失败还有 5s 重试兜底。
            self.flushSettings()
        }
    }

    private func cancelDebouncedSettingsWrite() {
        debouncedSettingsWriteTask?.cancel()
        debouncedSettingsWriteTask = nil
    }

    /// 无条件把当前内存快照落盘(防抖窗口到点 / 退出 / 场景切换时调用)。
    ///
    /// 注意不能以"是否存在 pending 任务"为前置:重试任务到点时会先清空
    /// `debouncedSettingsWriteTask` 再进来,若此处提前 return,重试就成了空转,
    /// 内存与文件会无限期背离。
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

    /// 写盘失败后按 base×次数 退避重试(5s→10s→15s…),最多 `maxFlushRetryCount` 次,
    /// 超限放弃,避免内存与文件无限期背离(磁盘满/瞬时权限)。
    /// 此前注释写"重试一次",实现却是重试任务醒来先清句柄再 flush、失败后本方法的
    /// guard 恒为真 → 每 5s 一次同步写加一条 error 日志,永不收敛;现以计数封顶。
    /// 重试成功或下一次变更/直接写盘成功(persistSettings/Debounced、换根)会把计数
    /// 归零重新开始。
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
        // 跨 Store 原子提交的前提是共用同一数据目录,运行时校验防注入分叉导致
        // 内存与磁盘静默背离(同 RepositoryStore.removeRepository)。
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

        // 落盘成功后才取消 pending 的防抖写(原先在 save 之前):旧快照的写此刻已无
        // 意义,而挪到成功之后可让**失败路径**保留 pending 任务——换根失败时内存仍是
        // 旧值,防抖写照常落地,不会"取消后不补排"造成内存与 settings.json 短期背离。
        // 本函数到此没有任何 await,任务不会在中途跑掉,成功路径语义与原先完全等价。
        cancelDebouncedSettingsWrite()

        settings = updatedSettings
        // 换根直接写盘成功:归零重试预算。此前只在 persistSettings/flushSettings 归零,
        // 若此前已封顶(=5),换根成功后下一次 flush 失败会立刻放弃、零重试。
        flushRetryCount = 0
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
            // 经 UserFacingError 收口:换根路径失败会抛 JSONFileStore/POSIX 错误,
            // 裸 localizedDescription 会把系统英文原文打进引导页的设置横幅。
            return "保存失败：\(UserFacingError.message(for: error))"
        }
    }

    /// 仅清除 API Key(Base URL 与模型名保留):换 Key、或改用本地服务时的正规入口。
    /// 设置页「清除密钥」按钮的落地点;与"清空 Key 输入框后保存"等价,
    /// 但一键完成且不牵动其他字段的未保存修改。
    /// 无 AI 配置(`aiSettings == nil`)时为 no-op:没有可清的 Key。
    func clearStoredAPIKey() throws {
        guard var ai = settings.aiSettings else { return }
        ai.apiKey = ""
        var updatedSettings = settings
        updatedSettings.aiSettings = ai
        try persistSettings(updatedSettings)
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

    /// 保存 AI 服务配置;传 nil 表示清除配置(`aiSettings` 整体落盘为 nil)。
    ///
    /// API Key 明文随配置落盘,**所见即所存**:设置页首帧回显的就是已存值,
    /// 清空输入框后保存即删除已存 Key(显式动作,与钥匙串时代需要回读保护的
    /// 场景不同——本地文件回显不存在"读失败折叠成空串"的歧义);
    /// 单独删除另有 `clearStoredAPIKey` 一键入口。
    /// `persistSettings` 先写盘后改内存,失败时内存保持旧值并抛给调用方提示。
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
