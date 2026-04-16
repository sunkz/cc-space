import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            if let feedback {
                CCSpaceFeedbackBanner(feedback: feedback)
                    .ccspaceAutoDismissFeedback($feedback)
            }

            HStack(alignment: .center, spacing: 8) {
                TextField("仓库地址", text: $gitURL)
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
                    Text("新增")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!addPresentationState.canSubmit)
            }

            if repositories.isEmpty == false {
                TextField("搜索仓库名称或地址", text: $searchText)
                    .textFieldStyle(.roundedBorder)
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
