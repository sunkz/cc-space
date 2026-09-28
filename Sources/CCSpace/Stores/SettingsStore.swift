import Foundation
import os

private let settingsStoreLog = Logger(
    subsystem: "com.ccspace.app",
    category: "SettingsStore"
)

enum SettingsStoreError: LocalizedError, Equatable {
    case crossStoreRootMismatch
    case keychainDeleteFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .crossStoreRootMismatch:
            return "内部状态异常：设置与工作区的数据目录不一致，已取消本次操作"
        case .keychainDeleteFailed(let reason):
            return "清除 AI 配置失败：无法删除钥匙串中的旧 API Key（\(reason)），配置已保留，请稍后重试"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let fileStore: JSONFileStore
    private let keychain: any APIKeySecretStore
    private var debouncedSettingsWriteTask: Task<Void, Never>?
    /// 启动一次性迁移是否已执行(见 `performLaunchMigrationIfNeeded`)。
    private var didRunLaunchMigration = false
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
    /// 最近一次钥匙串写入是否成功:false 表示 API Key 处于明文降级保存态。
    /// @Published:View 需据此绑定"明文降级"警告横幅,降级态变化必须实时可见。
    /// 口径是"是否处于明文降级态"而非字面"钥匙串里有 Key":配置清空后不存在
    /// 任何密钥、也无从降级,同样取 true(见 `updateAISettings` 清空分支)。
    @Published private(set) var apiKeyStoredInKeychain = true

    init(
        fileStore: JSONFileStore,
        keychain: any APIKeySecretStore = SecurityAPIKeyStore.shared,
        flushRetryBaseSeconds: Int = 5
    ) {
        self.fileStore = fileStore
        self.keychain = keychain
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
        // 迁移/钥匙串回读必须在**构造路径**内完成:SettingsView → AISettingsSection
        // 的 `@State initialValue` 按构造时的 `aiSettings.apiKey` 赋值,晚于首帧的
        // 迁移(onAppear)来不及回填——`@State` 只在首次安装取一次初值,输入框会永远
        // 停在空串,用户随后保存会把钥匙串里的真 Key 覆盖成空(空串语义是删除)。
        // 曾顾虑"放进 init 等于每次视图结构体重建都跑一遍",该担忧已由
        // RootSplitView 里 `StateObject(wrappedValue:)` 的 autoclosure 消灭:
        // 它在视图生命周期内只求值一次,本 init 只执行一次。
        performLaunchMigrationIfNeeded()
    }

    /// 启动一次性迁移/回填(钥匙串收敛、托管态密钥回读、明文空串态标记)。
    ///
    /// 由 `init` 末尾调用(构造即回填,保证任何"body 期读 `aiSettings.apiKey`"的
    /// 消费方拿到的都是完整配置),与 `JSONFileStore.cleanupStaleStagingDirectories`
    /// 只在启动跑一次的惯例一致;幂等:重复调用由 `didRunLaunchMigration` 挡掉。
    func performLaunchMigrationIfNeeded() {
        guard didRunLaunchMigration == false else { return }
        didRunLaunchMigration = true
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
            // 明文态但本来就是空串:标记托管(编码不会再写字段)并顺手落盘收敛,
            // 否则每次启动都会重复走到这里改内存、文件却一直留着旧的空 apiKey 字段。
            ai.apiKeyManagedExternally = true
            settings.aiSettings = ai
            do {
                try fileStore.save(settings, as: "settings.json")
                // 迁移只在 init 执行(彼时 flushRetryCount 恒为 0),归零是防御性写法:
                // 万一未来在启动后复用本方法,直接写盘成功同样要归零重试预算
                // (否则封顶后下一次 flush 失败会零重试)。
                flushRetryCount = 0
            } catch {
                settingsStoreLog.error("event=empty_plaintext_api_key_rewrite_failed reason=\(error.localizedDescription, privacy: .public)")
            }
            return
        }
        do {
            try keychain.storeAPIKey(plaintext)
            ai.apiKeyManagedExternally = true
            settings.aiSettings = ai
            do {
                try fileStore.save(settings, as: "settings.json")
                // 同上:防御性归零(迁移仅在 init 执行,此时计数恒为 0)。
                flushRetryCount = 0
                settingsStoreLog.notice("event=api_key_migrated_to_keychain")
            } catch {
                // 迁移已写入钥匙串,落盘失败只说明明文还会多留一份,下次启动重试即可。
                settingsStoreLog.error("event=keychain_migration_rewrite_failed reason=\(error.localizedDescription, privacy: .public)")
            }
        } catch {
            apiKeyStoredInKeychain = false
            settingsStoreLog.error("event=keychain_migration_failed reason=\(error.localizedDescription, privacy: .public)")
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
    /// 归零重新开始;启动迁移只在 init 执行(彼时计数恒为 0),不构成归零路径。
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
    /// 输入为空而钥匙串处于"已存"态时先回读确认(读失败会把空串折叠进内存),
    /// 读不到就跳过钥匙串写入,绝不按空串删除既有 Key。
    /// 钥匙串写入先于落盘:落盘失败(磁盘满等)时回滚内存与降级标记到旧值,
    /// 钥匙串里可能暂存新 Key,与文件短暂不一致,由下次保存或启动迁移收敛。
    func updateAISettings(_ aiSettings: AppSettings.AISettings?) throws {
        let previousSettings = settings
        let previousStoredInKeychain = apiKeyStoredInKeychain
        var updatedSettings = settings
        var keychainWriteSucceeded = false
        if var ai = aiSettings {
            // 空串落钥匙串的语义是**删除**,而内存里的空串可能只是钥匙串读失败的
            // 折叠产物(`KeychainStore.readAPIKey` 对"无条目"与锁屏/ACL 拒绝一律返回
            // nil,上层分不出来):用户只改 Base URL 就保存,会把真 Key 永久删掉。
            // 因此存前先回读确认——读得到就按真 Key 保存(空串只是启动回显失败,
            // 仅凭空输入分不出"用户清空"与"没读到",宁可保留旧 Key;关闭 AI 的正规
            // 入口是清空 Base URL 与模型名 → updateAISettings(nil));仍读不到则跳过
            // 钥匙串写入,既不删也不覆盖,真 Key 留在钥匙串等下次回读恢复。
            var skipKeychainWrite = false
            if ai.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               apiKeyStoredInKeychain {
                if let stored = keychain.readAPIKey(),
                   stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    ai.apiKey = stored
                } else {
                    skipKeychainWrite = true
                    ai.apiKeyManagedExternally = true
                    settingsStoreLog.error("event=api_key_write_skipped detail=钥匙串读不到既有 Key,跳过空串写入以免误删")
                }
            }
            // skipKeychainWrite 时不动钥匙串也不动降级标记:文件里本就没有明文,
            // 真 Key 仍在钥匙串,不构成明文降级态。
            if skipKeychainWrite == false {
                do {
                    try keychain.storeAPIKey(ai.apiKey)
                    ai.apiKeyManagedExternally = true
                    apiKeyStoredInKeychain = true
                    keychainWriteSucceeded = true
                } catch {
                    ai.apiKeyManagedExternally = false
                    apiKeyStoredInKeychain = false
                    settingsStoreLog.error("event=keychain_store_failed reason=\(error.localizedDescription, privacy: .public)")
                }
            }
            updatedSettings.aiSettings = ai
        } else {
            do {
                try keychain.storeAPIKey("")
                // 清空成功路径按真实状态归位,取 true(口径见属性声明:是否处于
                // 明文降级态)。逐一核过消费方:① AISettingsSection 的降级横幅仅在
                // false 时显示"API Key 正以明文保存在 settings.json 中"——此刻
                // aiSettings 已为 nil、钥匙串条目已删,置 false 会谎报明文落盘,
                // 是实打实的 UI 副作用;② 本方法开头的空串回读保护(仅对随后的
                // 非空配置保存生效)在钥匙串已空时回读 nil、安全跳过,不依赖此值。
                // 故"无密钥可存、也无明文可降级"的真实状态即"非降级态"= true。
                apiKeyStoredInKeychain = true
                keychainWriteSucceeded = true
            } catch {
                // 删除失败不能"悄悄清除":旧 Key 仍躺在钥匙串里,照常落盘
                // aiSettings = nil 会让 storedInKeychain 与真实态背离,且用户随后
                // 重新配置、Key 留空时会被开头的回读保护把旧 Key 无声复活。
                // 中止本次清除并抛错(UI 经 errorDescription 可见提示),配置原样保留。
                settingsStoreLog.error("event=keychain_delete_failed reason=\(error.localizedDescription, privacy: .public)")
                throw SettingsStoreError.keychainDeleteFailed(reason: error.localizedDescription)
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
                settingsStoreLog.error("event=ai_settings_persist_failed detail=密钥已写入钥匙串但配置保存失败 reason=\(error.localizedDescription, privacy: .public)")
            } else {
                settingsStoreLog.error("event=ai_settings_persist_failed reason=\(error.localizedDescription, privacy: .public)")
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
