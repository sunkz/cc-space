import SwiftUI

@main
struct CCSpace: App {

    private let launchConfiguration = CCSpaceLaunchConfiguration()
    private let gitService = GitService()
    /// 独立窗口(Diff/提交记录)的破坏性写统一走协调器:与主窗口后台操作共用 per-path 锁,
    /// 避免对同一工作树交错写。
    private let syncCoordinator: SyncCoordinator
    private let fileSystemService = FileSystemService()

    @MainActor init() {
        self.syncCoordinator = SyncCoordinator(gitService: gitService)
        JSONFileStore.cleanupStaleStagingDirectories(
            in: launchConfiguration.resolvedAppSupportDirectory()
        )
    }

    var body: some Scene {
        Window("CCSpace", id: "main") {
            RootSplitView(
                launchConfiguration: launchConfiguration,
                gitService: gitService
            )
        }
        .defaultSize(
            width: launchConfiguration.windowSize.width,
            height: launchConfiguration.windowSize.height
        )

        WindowGroup(for: DiffWindowPayload.self) { $payload in
            if let payload {
                DiffWindowView(
                    payload: payload,
                    gitService: gitService,
                    syncCoordinator: syncCoordinator,
                    fileSystemService: fileSystemService
                )
            } else {
                // 窗口创建瞬间 value 可能短暂为 nil:给中性底色避免闪白。
                Color(nsColor: .windowBackgroundColor)
                    .frame(minWidth: 560, minHeight: 360)
            }
        }
        .defaultSize(width: 720, height: 520)

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
