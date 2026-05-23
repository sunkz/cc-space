import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    @Binding var showOnboarding: Bool
    @State private var saveFeedback: CCSpaceFeedback?

    init(
        settingsStore: SettingsStore,
        repositoryStore: RepositoryStore,
        workplaceStore: WorkplaceStore,
        gitService: GitServicing,
        showOnboarding: Binding<Bool>
    ) {
        self.settingsStore = settingsStore
        self.repositoryStore = repositoryStore
        self.workplaceStore = workplaceStore
        self.gitService = gitService
        self._showOnboarding = showOnboarding
    }

    private var savedPath: String {
        settingsStore.settings.workplaceRootPath
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
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

                    if repositoryStore.repositories.count > 8 {
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

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            do {
                try settingsStore.updateRootPath(path)
                saveFeedback = CCSpaceFeedback(style: .success, message: "设置已保存")
            } catch {
                saveFeedback = CCSpaceFeedbackFactory.actionError(
                    action: "保存设置",
                    error: error
                )
            }
        }
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
