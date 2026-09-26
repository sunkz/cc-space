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
    private let keychain: any APIKeySecretStore
    private var debouncedSettingsWriteTask: Task<Void, Never>?

    /// 本次启动 settings.json 是否损坏并被重置为默认值。
    /// 上游 View 可据此提示用户配置已重置(而不是让用户以为自己没设置过)。
    private(set) var didRecoverFromCorruptFile = false
    /// 最近一次钥匙串写入是否成功:false 表示 API Key 处于明文降级保存态。
    /// @Published:View 需据此绑定"明文降级"警告横幅,降级态变化必须实时可见。
    @Published private(set) var apiKeyStoredInKeychain = true

    init(fileStore: JSONFileStore, keychain: any APIKeySecretStore = SecurityAPIKeyStore.shared) {
        self.fileStore = fileStore
        self.keychain = keychain
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
        migrateAPIKeyOutOfSettingsFileIfNeeded()
    }

    /// 启动时把 API Key 收敛进钥匙串:
    /// - 明文态(旧版本 settings.json 带 apiKey):迁入钥匙串并立即重写 settings(去明文);
    ///   钥匙串此刻仍不可用则保留明文(降级态),下次启动或下次保存再收敛。
    /// - 托管态(文件无 apiKey):从钥匙串读回内存,保证本进程内 `settings.aiSettings.apiKey`
    ///   与保存时同构(消费方——AI 服务、设置页——都按"完整配置"读)。
    private func migrateAPIKeyOutOfSettingsFileIfNeeded() {
        guard var ai = settings.aiSettings else { return }
        if ai.apiKeyManagedExternally {
            // 托管态:从钥匙串读回内存,保证本进程内 `settings.aiSettings.apiKey`
            // 与保存时同构(消费方——AI 服务、设置页——都按"完整配置"读)。
            settings.backfillAPIKeyFromKeychainIfManaged(using: keychain)
            return
        }
        let plaintext = ai.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plaintext.isEmpty == false else {
            // 明文态但本来就是空串:无事可做,直接标记托管(编码不会再写字段)。
            ai.apiKeyManagedExternally = true
            settings.aiSettings = ai
            return
        }
        do {
            try keychain.storeAPIKey(plaintext)
            ai.apiKeyManagedExternally = true
            settings.aiSettings = ai
            do {
                try fileStore.save(settings, as: "settings.json")
                settingsStoreLog.notice("event=api_key_migrated_to_keychain")
            } catch {
                // 迁移已写入钥匙串,落盘失败只说明明文还会多留一份,下次启动重试即可。
                settingsStoreLog.error("event=keychain_migration_rewrite_failed reason=\(error.localizedDescription)")
            }
        } catch {
            apiKeyStoredInKeychain = false
            settingsStoreLog.error("event=keychain_migration_failed reason=\(error.localizedDescription)")
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
        } catch {
            settingsStoreLog.error("event=flush_settings_failed reason=\(error.localizedDescription)")
            scheduleFlushRetry()
        }
    }

    /// 写盘失败后 5s 重试一次,避免内存与文件无限期背离(磁盘满/瞬时权限)。
    private func scheduleFlushRetry() {
        guard debouncedSettingsWriteTask == nil else { return }
        debouncedSettingsWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
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

    /// 保存 AI 服务配置;传 nil 表示清除配置(钥匙串条目一并删除)。
    ///
    /// API Key 优先落钥匙串;钥匙串不可用时降级为明文落盘(编码带 apiKey 字段),
    /// 不静默丢用户配置。成功迁入钥匙串后,若上一轮是降级明文态,本次落盘即完成收敛。
    /// 钥匙串写入先于落盘:落盘失败(磁盘满等)时回滚内存与降级标记到旧值,
    /// 钥匙串里可能暂存新 Key,与文件短暂不一致,由下次保存或启动迁移收敛。
    func updateAISettings(_ aiSettings: AppSettings.AISettings?) throws {
        let previousSettings = settings
        let previousStoredInKeychain = apiKeyStoredInKeychain
        var updatedSettings = settings
        var keychainWriteSucceeded = false
        if var ai = aiSettings {
            do {
                try keychain.storeAPIKey(ai.apiKey)
                ai.apiKeyManagedExternally = true
                apiKeyStoredInKeychain = true
                keychainWriteSucceeded = true
            } catch {
                ai.apiKeyManagedExternally = false
                apiKeyStoredInKeychain = false
                settingsStoreLog.error("event=keychain_store_failed reason=\(error.localizedDescription)")
            }
            updatedSettings.aiSettings = ai
        } else {
            do {
                try keychain.storeAPIKey("")
                apiKeyStoredInKeychain = true
                keychainWriteSucceeded = true
            } catch {
                apiKeyStoredInKeychain = false
                settingsStoreLog.error("event=keychain_delete_failed reason=\(error.localizedDescription)")
            }
            updatedSettings.aiSettings = nil
        }
        do {
            try persistSettings(updatedSettings)
        } catch {
            // 落盘失败:内存与降级标记回滚到旧值,维持"内存 == 文件"的一致口径。
            settings = previousSettings
            apiKeyStoredInKeychain = previousStoredInKeychain
            if keychainWriteSucceeded {
                settingsStoreLog.error("event=ai_settings_persist_failed detail=密钥已写入钥匙串但配置保存失败 reason=\(error.localizedDescription)")
            } else {
                settingsStoreLog.error("event=ai_settings_persist_failed reason=\(error.localizedDescription)")
            }
            throw error
        }
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
