import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    @State private var saveFeedback: CCSpaceFeedback?

    init(
        settingsStore: SettingsStore,
        repositoryStore: RepositoryStore,
        workplaceStore: WorkplaceStore,
        gitService: GitServicing
    ) {
        self.settingsStore = settingsStore
        self.repositoryStore = repositoryStore
        self.workplaceStore = workplaceStore
        self.gitService = gitService
    }

    private var savedPath: String {
        settingsStore.settings.workplaceRootPath
    }

    private var missingRootPathFeedback: CCSpaceFeedback? {
        savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CCSpaceFeedback(style: .warning, message: "请先设置根目录。")
            : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rootDirectorySection
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
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(12)
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
                subtitle: "新建工作区时，会默认在这里创建本地目录。",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            HStack(spacing: 8) {
                Text(savedPath.isEmpty ? "未设置" : savedPath)
                    .font(.body)
                    .foregroundStyle(savedPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Button("选择目录") {
                    chooseDirectory()
                }
                .ccspacePrimaryActionButton()
            }
            .ccspaceInsetPanel(
                background: Color.primary.opacity(0.02),
                cornerRadius: 12,
                padding: 10,
                borderOpacity: 0.04
            )

            if let saveFeedback {
                CCSpaceFeedbackBanner(feedback: saveFeedback)
                    .ccspaceAutoDismissFeedback($saveFeedback)
            }

            if let missingRootPathFeedback {
                CCSpaceFeedbackBanner(feedback: missingRootPathFeedback)
            }
        }
        .ccspacePanel(
            background: .clear,
            cornerRadius: 12,
            padding: 12,
            borderOpacity: 0.03
        )
    }

}
