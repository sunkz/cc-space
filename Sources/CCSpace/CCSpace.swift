import SwiftUI
import os

/// 文件级 logger:App 类型隐式 @MainActor,成员静态属性会被连带隔离,
/// 而 settingsReader 是非隔离 Sendable 闭包,只能引用 nonisolated 的日志器。
private let appStartupLog = Logger(
    subsystem: "com.ccspace.app",
    category: "App"
)

@main
struct CCSpace: App {

    private let launchConfiguration = CCSpaceLaunchConfiguration()
    private let gitService = GitService()
    /// 独立窗口(Diff/提交记录)的破坏性写操作统一走协调器:
    /// 与主窗口后台 pull/push/切分支共用 per-path 锁,避免对同一工作树交错写。
    private let syncCoordinator: SyncCoordinator
    private let aiCommitService: AICommitMessageService

    @MainActor init() {
        self.syncCoordinator = SyncCoordinator(gitService: gitService)
        let appSupportDirectory = launchConfiguration.resolvedAppSupportDirectory()
        // 清理上次崩溃/强退遗留的 JSON 写入暂存目录。**只在启动调用一次**:
        // JSONFileStore 在运行期会被反复构造,清理逻辑不能放在它的 init 里,
        // 否则会删掉正在进行中的写入暂存目录。
        JSONFileStore.cleanupStaleStagingDirectories(in: appSupportDirectory)

        // AI 服务(提交信息生成/测试连接/模型列表):Diff 独立窗口与主窗口的
        // SettingsStore 不共享状态,服务在每次请求时直接读盘取最新配置,变更即时生效。
        // API Key 已迁钥匙串(见 SecurityAPIKeyStore):读盘结果里的 apiKey 恒为空,
        // 这里按托管态补读钥匙串,再交给服务消费。
        let settingsFileStore = JSONFileStore(
            rootDirectory: appSupportDirectory
        )
        let keychain = SecurityAPIKeyStore.shared
        aiCommitService = AICommitMessageService(
            settingsReader: {
                do {
                    var settings = try settingsFileStore.loadIfPresent(
                        AppSettings.self,
                        from: "settings.json",
                        default: AppSettings(workplaceRootPath: "")
                    )
                    // API Key 已迁钥匙串:读盘结果里的 apiKey 恒为空,
                    // 这里按托管态补读钥匙串,再交给服务消费(规则见 AppSettings 扩展)。
                    settings.backfillAPIKeyFromKeychainIfManaged(using: keychain)
                    return settings
                } catch {
                    // 此前 `try?` 吞掉全部读盘/解码错误:settings.json 临时不可读时
                    // AI 功能静默降级为"未配置",现场无任何日志可查。
                    appStartupLog.error("event=settings_reader_failed reason=\(error.localizedDescription)")
                    return nil
                }
            }
        )
    }

    var body: some Scene {
        Window("CCSpace", id: "main") {
            RootSplitView(
                launchConfiguration: launchConfiguration,
                gitService: gitService,
                aiService: aiCommitService
            )
        }
        .defaultSize(
            width: launchConfiguration.windowSize.width,
            height: launchConfiguration.windowSize.height
        )

        // Diff 查看器:普通窗口(非模态),不阻塞主窗口操作。
        WindowGroup(for: DiffWindowPayload.self) { $payload in
            if let payload {
                DiffWindowView(
                    payload: payload,
                    gitService: gitService,
                    syncCoordinator: syncCoordinator,
                    aiCommitService: aiCommitService
                )
            } else {
                // 窗口创建瞬间 value 可能短暂为 nil,给个与内容同尺寸的中性底色避免闪白。
                Color(nsColor: .windowBackgroundColor)
                    .frame(minWidth: 560, minHeight: 360)
            }
        }
        .defaultSize(width: 720, height: 520)

        // 提交记录:普通窗口(非模态),支持分支切换/详情展开/基于提交建分支。
        WindowGroup(for: CommitLogWindowPayload.self) { $payload in
            if let payload {
                CommitLogWindowView(
                    payload: payload,
                    gitService: gitService,
                    syncCoordinator: syncCoordinator
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .frame(minWidth: 560, minHeight: 420)
            }
        }
        .defaultSize(width: 640, height: 540)

        // 分支比较:from/to 可切换的对比窗口,复用 Diff 查看器展示文件级差异。
        WindowGroup(for: BranchCompareWindowPayload.self) { $payload in
            if let payload {
                BranchCompareWindowView(
                    payload: payload,
                    gitService: gitService
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .frame(minWidth: 720, minHeight: 460)
            }
        }
        .defaultSize(width: 860, height: 600)
    }
}
