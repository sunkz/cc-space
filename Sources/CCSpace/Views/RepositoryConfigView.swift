import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RepositorySettingsSection: View {
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    @State private var gitURL: String = ""
    @State private var searchText: String = ""
    @State private var feedback: CCSpaceFeedback?
    @State private var editingRepositoryID: UUID?
    @State private var editingGitURL: String = ""
    @State private var deletePresentationState: RepositoryDeletePresentationState?

    private var repositories: [RepositoryConfig] {
        repositoryStore.repositories.sorted {
            $0.repoName.localizedStandardCompare($1.repoName) == .orderedAscending
        }
    }

    private var addPresentationState: RepositoryAddPresentationState {
        RepositoryAddPresentationState(gitURL: gitURL)
    }

    private var searchPresentationState: RepositorySearchPresentationState {
        RepositorySearchPresentationState(
            repositories: repositories,
            searchText: searchText
        )
    }

    private func editPresentationState(for repository: RepositoryConfig) -> RepositoryEditPresentationState {
        RepositoryEditPresentationState(
            repository: repository,
            editingRepositoryID: editingRepositoryID,
            editingGitURL: editingGitURL
        )
    }

    private var repositoryCountLabel: String {
        "\(repositories.count) 个仓库"
    }

    @MainActor
    private func addRepository() async {
        guard addPresentationState.canSubmit else { return }
        let trimmedGitURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            feedback = nil
            let repositoryName = try GitURLParser.repositoryName(from: trimmedGitURL)
            try repositoryStore.addRepository(gitURL: trimmedGitURL)
            gitURL = ""
            feedback = RepositoryConfigFeedbackFactory.addSuccess(repositoryName: repositoryName)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "新增仓库",
                error: error
            )
        }
    }

    private func exportRepositoriesBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "导出 Git 仓库备份"
        panel.message = "请输入备份文件名并选择保存位置"
        panel.nameFieldStringValue = RepositoryBackupExportPresentationState.defaultFileName()
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = try repositoryStore.exportBackup(to: url)
            feedback = RepositoryConfigFeedbackFactory.exportSuccess(
                repositoryCount: document.repositories.count
            )
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "导出仓库备份",
                error: error
            )
        }
    }

    private func importRepositoriesBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try repositoryStore.importBackup(from: url)
            feedback = RepositoryConfigFeedbackFactory.importResult(result)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "导入仓库备份",
                error: error
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            backupActionSection

            if let feedback {
                CCSpaceFeedbackBanner(feedback: feedback)
                    .ccspaceAutoDismissFeedback($feedback)
            }

            addRepositorySection

            if repositories.isEmpty == false {
                TextField("搜索仓库名称或地址", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 2)
            }

            if searchPresentationState.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: searchPresentationState.emptyTitle,
                    subtitle: searchPresentationState.emptySubtitle,
                    systemImage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass",
                    tint: .accentColor
                ) {
                    EmptyView()
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(searchPresentationState.filteredRepositories) { repository in
                        repositoryRow(repository)
                    }
                }
            }
        }
        .alert(
            deletePresentationState?.title ?? "",
            isPresented: Binding(
                get: { deletePresentationState != nil },
                set: { isPresented in
                    if isPresented == false {
                        deletePresentationState = nil
                    }
                }
            )
        ) {
            if let deletePresentationState, deletePresentationState.isBlocked == false {
                Button(deletePresentationState.confirmLabel, role: .destructive) {
                    confirmDeleteRepository()
                }
                Button("取消", role: .cancel) {}
            } else {
                Button("知道了", role: .cancel) {}
            }
        } message: {
            Text(deletePresentationState?.message ?? "")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "集中维护常用 Git URL，并支持导入导出备份。",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            Spacer(minLength: 12)

            CCSpacePill(
                title: repositoryCountLabel,
                systemImage: "shippingbox",
                tint: .secondary
            )
        }
    }

    private var backupActionSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("仓库备份")
                    .font(.subheadline.weight(.medium))
                Text("导出为 JSON 备份文件，或从已有备份中恢复仓库配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("导入备份") {
                importRepositoriesBackup()
            }
            .ccspaceSecondaryActionButton()

            Button("导出备份") {
                exportRepositoriesBackup()
            }
            .ccspacePrimaryActionButton()
        }
        .ccspaceInsetPanel(
            background: Color.primary.opacity(0.02),
            cornerRadius: 12,
            padding: 10,
            borderOpacity: 0.04
        )
    }

    private var addRepositorySection: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("粘贴 Git 仓库地址（HTTPS 或 SSH）", text: $gitURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: gitURL) { _, _ in
                    feedback = nil
                }
                .onSubmit {
                    Task { await addRepository() }
                }

            Button {
                Task {
                    await addRepository()
                }
            } label: {
                Text("新增仓库")
            }
            .ccspacePrimaryActionButton()
            .disabled(!addPresentationState.canSubmit)
        }
        .ccspaceInsetPanel(
            background: Color.primary.opacity(0.02),
            cornerRadius: 12,
            padding: 10,
            borderOpacity: 0.04
        )
    }

    @ViewBuilder
    private func repositoryRow(_ repository: RepositoryConfig) -> some View {
        let presentationState = editPresentationState(for: repository)
        if presentationState.isEditing {
            CCSpaceInteractiveCard(selected: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "shippingbox.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(repository.repoName)
                                .font(.body.weight(.medium))
                            TextField("Git 仓库地址", text: $editingGitURL)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: editingGitURL) { _, _ in
                                    feedback = nil
                                }
                                .onSubmit {
                                    saveEditing(repository)
                                }
                        }
                    }

                    HStack(spacing: 6) {
                        Spacer()
                        Button("取消") {
                            cancelEditing()
                        }
                        .ccspaceSecondaryActionButton()

                        Button("保存") {
                            saveEditing(repository)
                        }
                        .ccspacePrimaryActionButton()
                        .disabled(!presentationState.canSubmit)
                    }
                }
            }
        } else {
            CCSpaceInteractiveCard(selected: false) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.repoName)
                            .font(.body.weight(.medium))
                        Text(repository.gitURL)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Button {
                            startEditing(repository)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .ccspaceCompactActionButton()
                        .ccspaceQuickHelp("编辑仓库地址")

                        Button(role: .destructive) {
                            prepareDelete(repository)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .ccspaceCompactActionButton()
                        .ccspaceQuickHelp("删除仓库")
                    }
                }
            }
        }
    }

    private func removeRepository(_ id: UUID) {
        let repositoryName = repositoryStore.repositories.first { $0.id == id }?.repoName
        do {
            try repositoryStore.removeRepository(id: id, workplaceStore: workplaceStore)
            if editingRepositoryID == id {
                cancelEditing()
            }
            if let repositoryName {
                feedback = RepositoryConfigFeedbackFactory.deleteSuccess(repositoryName: repositoryName)
            } else {
                feedback = nil
            }
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "删除仓库",
                error: error
            )
        }
    }

    private func prepareDelete(_ repository: RepositoryConfig) {
        deletePresentationState = RepositoryDeletePresentationState(
            repository: repository,
            workplaces: workplaceStore.workplaces
        )
    }

    private func confirmDeleteRepository() {
        guard let repositoryID = deletePresentationState?.repositoryID else { return }
        deletePresentationState = nil
        removeRepository(repositoryID)
    }

    private func saveEditing(_ repository: RepositoryConfig) {
        let trimmedEditingGitURL = editingGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            feedback = nil
            try repositoryStore.updateRepository(
                id: repository.id,
                gitURL: trimmedEditingGitURL
            )
            cancelEditing()
            feedback = RepositoryConfigFeedbackFactory.updateSuccess(repositoryName: repository.repoName)
        } catch {
            feedback = CCSpaceFeedbackFactory.actionError(
                action: "更新仓库",
                error: error
            )
        }
    }

    private func startEditing(_ repository: RepositoryConfig) {
        feedback = nil
        editingRepositoryID = repository.id
        editingGitURL = repository.gitURL
    }

    private func cancelEditing() {
        editingRepositoryID = nil
        editingGitURL = ""
    }
}
