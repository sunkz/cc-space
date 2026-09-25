import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    let aiService: AIServiceInfoServicing
    @Binding var showOnboarding: Bool
    @State private var saveFeedback: CCSpaceFeedback?
    /// 当前页签:通用设置 / AI 配置。状态由 RootSplitView 持有(标题栏 tab 栏在根工具栏渲染)。
    @Binding var selectedTab: SettingsTab

    init(
        settingsStore: SettingsStore,
        repositoryStore: RepositoryStore,
        workplaceStore: WorkplaceStore,
        gitService: GitServicing,
        aiService: AIServiceInfoServicing,
        showOnboarding: Binding<Bool>,
        selectedTab: Binding<SettingsTab>
    ) {
        self.settingsStore = settingsStore
        self.repositoryStore = repositoryStore
        self.workplaceStore = workplaceStore
        self.gitService = gitService
        self.aiService = aiService
        self._showOnboarding = showOnboarding
        self._selectedTab = selectedTab
    }

    private var savedPath: String {
        settingsStore.settings.workplaceRootPath
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == .general {
                        generalTabContent
                    } else {
                        AISettingsSection(settingsStore: settingsStore, aiService: aiService)
                    }

                    if selectedTab == .general, repositoryStore.repositories.count > 8 {
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
        .ccspaceScreenBackground()
        .navigationTitle("设置")
    }

    // MARK: - 通用设置页签

    private var generalTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            rootDirectorySection
                .id("settings-top")
            RepositorySettingsSection(
                repositoryStore: repositoryStore,
                workplaceStore: workplaceStore,
                gitService: gitService
            )
                .ccspacePanel(
                    background: .clear,
                    cornerRadius: 12,
                    padding: 12,
                    borderOpacity: 0.03
                )

            restartOnboardingSection
        }
    }

    // MARK: - 标题栏 tab 栏(独立视图 SettingsTabBar,由 RootSplitView 挂在 principal 位置)

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            do {
                // 换根与工作区路径迁移一次原子提交(settings.json + workplaces/sync-states):
                // 分两步写盘时,若第二步失败,记录已指向新根而设置仍是旧根,
                // 下次磁盘刷新会把这些工作区判为"目录已删除"永久清理掉。
                let rebasedCount = try settingsStore.updateRootPath(
                    path,
                    rebasingWorkplaceStore: workplaceStore
                )
                saveFeedback = CCSpaceFeedback(
                    style: .success,
                    message: Self.rebaseNotice(rebasedCount: rebasedCount)
                )
            } catch {
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
                    Text(savedPath)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Button("选择目录") {
                    chooseDirectory()
                }
                .ccspacePrimaryActionButton()
                .ccspaceQuickHelp("更改工作区存储位置")
            }
            .ccspaceInsetPanel(
                background: savedPath.isEmpty ? Color.orange.opacity(0.03) : Color.primary.opacity(0.02),
                cornerRadius: 12,
                padding: 10,
                borderOpacity: savedPath.isEmpty ? 0.08 : 0.04
            )

            if let saveFeedback {
                CCSpaceFeedbackBanner(feedback: saveFeedback)
                    .ccspaceAutoDismissFeedback($saveFeedback)
            }
        }
        .ccspacePanel(
            background: .clear,
            cornerRadius: 12,
            padding: 12,
            borderOpacity: 0.03
        )
    }

    private var restartOnboardingSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("重新体验新手引导流程")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新开始引导") {
                try? settingsStore.updateHasCompletedOnboarding(false)
                showOnboarding = true
            }
            .ccspaceSecondaryActionButton()
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

/// 标题栏居中的页签切换 [设置][AI]:由 RootSplitView 挂在工具栏 principal 位置。
/// 用系统分段控件(NSSegmentedControl)实现:选中滑块动画、玻璃容器、键盘与
/// VoiceOver 支持全部由系统提供,组件不画任何背景。AI 段用 Label 带 sparkles 图标。
struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        Picker("设置页签", selection: $selectedTab) {
            ForEach(SettingsTabPresentationState.allTabs, id: \.self) { tab in
                Text(tab.pickerTitle)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
