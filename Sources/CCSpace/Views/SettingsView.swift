import SwiftUI
import AppKit

struct SettingsView: View {
    /// 换根成功后的搬目录辅助:提示存续期间提供新旧目录的 Finder 入口。
    struct RebaseAssist: Equatable {
        let oldPath: String
        let newPath: String
    }

    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    let aiService: AIServiceInfoServicing
    @Binding var showOnboarding: Bool
    /// AI 表单未保存修改的上报通道(RootSplitView 持有,标题栏页签「•」标记消费)。
    @Binding var hasUnsavedAIChanges: Bool
    /// 当前页签:通用设置 / AI 配置。状态由 RootSplitView 持有(标题栏 tab 栏在根工具栏渲染)。
    @Binding var selectedTab: SettingsTab

    @State private var saveFeedback: CCSpaceFeedback?
    /// 重置引导的结果横幅:挂在引导区块自己的位置,错误不再落在视线外的顶部区块
    /// (此前与根目录共用 saveFeedback,横幅却只渲染在根目录区块内)。
    @State private var onboardingFeedback: CCSpaceFeedback?
    /// 仓库搜索词:与 RepositorySettingsSection 共享——「回到顶部」按过滤后条数判断。
    @State private var searchText = ""
    /// 根目录是否真实存在:目录可能在 App 外被移动/删除,进入设置页要能看出来。
    @State private var rootDirectoryExists: Bool
    /// 换根成功后的搬目录辅助;随 saveFeedback 一同收起。
    @State private var rebaseAssist: RebaseAssist?

    init(
        settingsStore: SettingsStore,
        repositoryStore: RepositoryStore,
        workplaceStore: WorkplaceStore,
        gitService: GitServicing,
        aiService: AIServiceInfoServicing,
        showOnboarding: Binding<Bool>,
        hasUnsavedAIChanges: Binding<Bool>,
        selectedTab: Binding<SettingsTab>
    ) {
        self.settingsStore = settingsStore
        self.repositoryStore = repositoryStore
        self.workplaceStore = workplaceStore
        self.gitService = gitService
        self.aiService = aiService
        self._showOnboarding = showOnboarding
        self._hasUnsavedAIChanges = hasUnsavedAIChanges
        self._selectedTab = selectedTab
        // 首帧即带真实存在性,避免先渲染"正常"再闪成"目录不存在"。
        _rootDirectoryExists = State(
            initialValue: Self.directoryExists(settingsStore.settings.workplaceRootPath)
        )
    }

    private var savedPath: String {
        settingsStore.settings.workplaceRootPath
    }

    private static func directoryExists(_ path: String) -> Bool {
        path.isEmpty == false && FileManager.default.fileExists(atPath: path)
    }

    private var rootDirectoryMissing: Bool {
        savedPath.isEmpty == false && rootDirectoryExists == false
    }

    var body: some View {
        // 两个页签各自持有独立 ScrollView、常驻视图树(透明度切换):
        // - 常驻:AI 表单里粘贴到一半的 Key 等未保存输入不会随切页被静默丢弃;
        // - 独立滚动:单 ScrollView 下两页签共享偏移,在通用页签滚到底再切 AI
        //   会停在空白区——各自持有时滚动位置随页签独立保留。
        // 隐藏侧禁用命中测试并对辅助功能隐藏,交互与 if/else 等价。
        ZStack(alignment: .topLeading) {
            generalTab
                .opacity(selectedTab == .general ? 1 : 0)
                .allowsHitTesting(selectedTab == .general)
                .accessibilityHidden(selectedTab != .general)
            aiTab
                .opacity(selectedTab == .ai ? 1 : 0)
                .allowsHitTesting(selectedTab == .ai)
                .accessibilityHidden(selectedTab != .ai)
        }
        .onChange(of: selectedTab) { _, _ in
            // 两页签视图常驻,隐藏侧的输入框不会自动交出第一响应者:
            // 在 AI 页签点过 Base URL 再切回通用,键盘会敲进隐藏字段。
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .ccspaceScreenBackground()
        .navigationTitle("设置")
    }

    // MARK: - 通用设置页签

    private var generalTab: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rootDirectorySection
                        .id("settings-top")
                    RepositorySettingsSection(
                        repositoryStore: repositoryStore,
                        workplaceStore: workplaceStore,
                        gitService: gitService,
                        searchText: $searchText
                    )
                    .ccspacePanel(
                        background: .clear,
                        cornerRadius: 12,
                        padding: 12,
                        borderOpacity: 0.03
                    )

                    restartOnboardingSection

                    if showsBackToTop {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    scrollProxy.scrollTo("settings-top", anchor: .top)
                                }
                            } label: {
                                Label("回到顶部", systemImage: "arrow.up")
                            }
                            .ccspaceCompactActionButton()
                            .ccspaceQuickHelp("回到顶部")
                            Spacer()
                        }
                        .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(12)
            }
        }
    }

    /// 「回到顶部」按**过滤后**的条数判断(纯逻辑见
    /// `RepositorySearchPresentationState.showsBackToTop`):搜索收窄到少数几条时
    /// 列表滚不出首屏,按钮没有意义——此前用原始总数,搜索态也会显示。
    private var showsBackToTop: Bool {
        RepositorySearchPresentationState(
            repositories: repositoryStore.repositories,
            searchText: searchText
        ).showsBackToTop
    }

    // MARK: - AI 配置页签

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AISettingsSection(
                    settingsStore: settingsStore,
                    aiService: aiService,
                    hasUnsavedChanges: $hasUnsavedAIChanges
                )
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(12)
        }
    }

    // MARK: - 动作

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            let previousPath = savedPath
            do {
                // 换根与工作区路径迁移一次原子提交(settings.json + workplaces/sync-states):
                // 分两步写盘时,若第二步失败,记录已指向新根而设置仍是旧根,
                // 下次磁盘刷新会把这些工作区判为"目录已删除"永久清理掉。
                let rebasedCount = try settingsStore.updateRootPath(
                    path,
                    rebasingWorkplaceStore: workplaceStore
                )
                // 真发生迁移才给搬目录辅助:重选同一目录等 no-op 场景保持普通保存提示。
                rebaseAssist = rebasedCount > 0 && previousPath.isEmpty == false
                    ? RebaseAssist(oldPath: previousPath, newPath: path)
                    : nil
                saveFeedback = CCSpaceFeedback(
                    style: .success,
                    message: Self.rebaseNotice(rebasedCount: rebasedCount)
                )
            } catch {
                rebaseAssist = nil
                saveFeedback = CCSpaceFeedbackFactory.actionError(
                    action: "保存设置",
                    error: error
                )
            }
        }
    }

    /// 换根之后,磁盘上的目录并不会被自动搬走,需要明确告诉用户下一步要做什么。
    /// 只看原子换根返回的迁移条数(本次真正被改写路径的工作区数),重选同一目录等
    /// no-op 场景保持普通保存提示,不弹"请手动移动目录"。
    private static func rebaseNotice(rebasedCount: Int) -> String {
        guard rebasedCount > 0 else { return "设置已保存" }
        return "设置已保存；\(rebasedCount) 个工作区已指向新位置，请手动把目录移动到新根目录"
    }

    private func refreshRootDirectoryExists() {
        rootDirectoryExists = Self.directoryExists(savedPath)
    }

    // MARK: - 区块

    private var rootDirectorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: "工作区根目录",
                subtitle: "工作区将以子文件夹形式创建在此目录下。",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            HStack(spacing: 8) {
                if savedPath.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundStyle(.orange)
                        Text("未设置")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(savedPath)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if rootDirectoryMissing {
                            Text("目录不存在，可能已被移动或删除")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        (rootDirectoryMissing ? Color.orange.opacity(0.06) : Color.primary.opacity(0.03)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }

                Button("选择目录") {
                    chooseDirectory()
                }
                .ccspacePrimaryActionButton()
                .ccspaceQuickHelp("更改工作区存储位置")
            }
            .ccspaceInsetPanel(
                background: savedPath.isEmpty || rootDirectoryMissing
                    ? Color.orange.opacity(0.03)
                    : Color.primary.opacity(0.02),
                cornerRadius: 12,
                padding: 10,
                borderOpacity: savedPath.isEmpty || rootDirectoryMissing ? 0.08 : 0.04
            )

            if let shownFeedback = saveFeedback {
                CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { saveFeedback = nil })
                    .ccspaceAutoDismissFeedback($saveFeedback)

                // 换根后目录要手动搬:横幅存续期间给新旧目录的 Finder 入口,
                // 两个窗口一开直接拖拽即可(横幅 3 秒自动关闭时一并收起)。
                if let rebaseAssist {
                    HStack(spacing: 8) {
                        Button("打开旧目录") {
                            WorkplaceSystemActions.showInFinder(at: rebaseAssist.oldPath)
                        }
                        .ccspaceSecondaryActionButton()
                        .ccspaceQuickHelp("在 Finder 中打开换根前的目录")

                        Button("打开新根目录") {
                            WorkplaceSystemActions.showInFinder(at: rebaseAssist.newPath)
                        }
                        .ccspaceSecondaryActionButton()
                        .ccspaceQuickHelp("在 Finder 中打开新的工作区根目录")
                    }
                }
            }
        }
        .ccspacePanel(
            background: .clear,
            cornerRadius: 12,
            padding: 12,
            borderOpacity: 0.03
        )
        .onChange(of: savedPath) { _, _ in
            // 选择目录(换根)后按新路径重新校验存在性。
            refreshRootDirectoryExists()
        }
        .onChange(of: saveFeedback) { _, newFeedback in
            // 提示关闭(手动/自动)后搬目录辅助一并收起。
            if newFeedback == nil { rebaseAssist = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 目录可能在 App 未激活期间被外部移动/删除,回到前台重新校验。
            refreshRootDirectoryExists()
        }
    }

    private var restartOnboardingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("重新体验新手引导流程")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新开始引导") {
                    // 不吞错:写盘失败下次启动也不会重放引导,用户以为"点了没反应"。
                    do {
                        try settingsStore.updateHasCompletedOnboarding(false)
                        showOnboarding = true
                    } catch {
                        onboardingFeedback = CCSpaceFeedbackFactory.actionError(
                            action: "重置引导状态",
                            error: error
                        )
                    }
                }
                .ccspaceSecondaryActionButton()
            }

            if let shownFeedback = onboardingFeedback {
                CCSpaceFeedbackBanner(feedback: shownFeedback, onClose: { onboardingFeedback = nil })
                    .ccspaceAutoDismissFeedback($onboardingFeedback)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .ccspacePanel(
            background: .clear,
            cornerRadius: 12,
            padding: 12,
            borderOpacity: 0.03
        )
    }

}

/// 标题栏居中的页签切换 [通用][AI]:由 RootSplitView 挂在工具栏 principal 位置。
/// 用系统分段控件(NSSegmentedControl)实现:选中滑块动画、玻璃容器、键盘与
/// VoiceOver 支持全部由系统提供,组件不画任何背景。AI 段用 Label 带 sparkles 图标;
/// AI 表单有未保存修改时段标题追加「•」(标记逻辑见 SettingsTabPresentationState)。
struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab
    /// AI 表单是否存在未保存修改(RootSplitView 持有,AISettingsSection 上报)。
    var showsUnsavedChanges: Bool = false

    private var presentationState: SettingsTabPresentationState {
        SettingsTabPresentationState(
            selectedTab: selectedTab,
            showsUnsavedChanges: showsUnsavedChanges
        )
    }

    var body: some View {
        Picker("设置页签", selection: $selectedTab) {
            ForEach(SettingsTabPresentationState.allTabs, id: \.self) { tab in
                Text(presentationState.pickerTitle(for: tab))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
