import SwiftUI

@main
struct CCSpace: App {
    private let launchConfiguration = CCSpaceLaunchConfiguration()
    private let gitService = GitService()
    private let aiCommitService: AICommitMessageService

    @MainActor init() {
        let appSupportDirectory = launchConfiguration.resolvedAppSupportDirectory()
        // 清理上次崩溃/强退遗留的 JSON 写入暂存目录。**只在启动调用一次**:
        // JSONFileStore 在运行期会被反复构造,清理逻辑不能放在它的 init 里,
        // 否则会删掉正在进行中的写入暂存目录。
        JSONFileStore.cleanupStaleStagingDirectories(in: appSupportDirectory)

        // AI 服务(提交信息生成/测试连接/模型列表):Diff 独立窗口与主窗口的
        // SettingsStore 不共享状态,服务在每次请求时直接读盘取最新配置,变更即时生效。
        let settingsFileStore = JSONFileStore(
            rootDirectory: appSupportDirectory
        )
        aiCommitService = AICommitMessageService(
            settingsReader: {
                try? settingsFileStore.loadIfPresent(
                    AppSettings.self,
                    from: "settings.json",
                    default: AppSettings(workplaceRootPath: "")
                )
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
                    gitService: gitService
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
