import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RepositorySettingsSection: View {
    @ObservedObject var repositoryStore: RepositoryStore
    @ObservedObject var workplaceStore: WorkplaceStore
    let gitService: GitServicing
    @State private var searchText: String = ""
    @State private var feedback: CCSpaceFeedback?
    @State private var deletePresentationState: RepositoryDeletePresentationState?
    @State private var showAddSheet = false
    @State private var editingSheetRepository: RepositoryConfig?
    /// "新增后直接编辑"的待弹层仓库:等 add sheet 的 onDismiss(完全收起)后再弹编辑 sheet,
    /// 避免两个 sheet 同帧在位导致第二个被系统静默丢弃。
    @State private var pendingEditAfterAdd: RepositoryConfig?

    private var repositories: [RepositoryConfig] {
        repositoryStore.repositories.sorted {
            $0.repoName.localizedStandardCompare($1.repoName) == .orderedAscending
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
        // repositories 是每次访问全量重排的计算属性,一次 body 求值会被触发多次:
        // 顶部取一次局部值,搜索展示状态也只构建一份沿渲染路径复用。
        let repositories = self.repositories
        let searchState = RepositorySearchPresentationState(
            repositories: repositories,
            searchText: searchText
        )
        return VStack(alignment: .leading, spacing: 12) {
            headerSection(repositoryCount: repositories.count)

            if let feedback {
                CCSpaceFeedbackBanner(feedback: feedback)
                    .ccspaceAutoDismissFeedback($feedback)
            }

            if repositories.isEmpty == false {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("搜索仓库名称或地址", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button {
                        showAddSheet = true
                    } label: {
                        Label("新增仓库", systemImage: "plus")
                    }
                    .ccspacePrimaryActionButton()
                }
            } else {
                addRepositorySection
            }

            if searchState.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: searchState.emptyTitle,
                    subtitle: searchState.emptySubtitle,
                    systemImage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass",
                    tint: .accentColor
                ) {
                    EmptyView()
                }
            } else {
                // 仓库列表全量平铺,随设置页整体滚动,不再固定高度内部滚动。
                repositoryList(searchState)
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
        .sheet(
            isPresented: $showAddSheet,
            onDismiss: {
                guard let pending = pendingEditAfterAdd else { return }
                pendingEditAfterAdd = nil
                editingSheetRepository = pending
            }
        ) {
            AddRepositorySheetView(
                repositoryStore: repositoryStore,
                infoService: RepositoryInfoService(gitService: gitService)
            ) { newRepo in
                pendingEditAfterAdd = newRepo
                feedback = RepositoryConfigFeedbackFactory.addSuccess(repositoryName: newRepo.repoName)
            }
        }
        .sheet(item: $editingSheetRepository) { repo in
            EditRepositorySheetView(
                repositoryStore: repositoryStore,
                repository: repo,
                infoService: RepositoryInfoService(gitService: gitService),
                onSaved: {
                    if let updated = repositoryStore.repositories.first(where: { $0.id == repo.id }) {
                        feedback = RepositoryConfigFeedbackFactory.updateSuccess(repositoryName: updated.repoName)
                    }
                }
            )
        }
    }

    private func repositoryList(_ searchState: RepositorySearchPresentationState) -> some View {
        LazyVStack(spacing: RepositoryListLayout.rowSpacing) {
            ForEach(searchState.filteredRepositories) { repository in
                repositoryRow(repository)
                    .id(repository.id)
            }
        }
    }

    private func headerSection(repositoryCount: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CCSpaceSectionTitle(
                title: "Git 仓库",
                subtitle: "在此添加的仓库可在创建工作区时直接勾选。",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            Spacer(minLength: 12)

            // 指示器与计数 pill 高度不同,内层按中心线对齐,避免跟随外层 .top 对齐错位。
            HStack(alignment: .center, spacing: 12) {
                GitEnvironmentStatusView(gitService: gitService)

                CCSpacePill(
                    title: "\(repositoryCount) 个仓库",
                    systemImage: "shippingbox",
                    tint: .secondary
                )
            }

            Button("导入") {
                importRepositoriesBackup()
            }
            .ccspaceSecondaryActionButton()
            .ccspaceQuickHelp("从 JSON 文件导入仓库配置")

            Button("导出") {
                exportRepositoriesBackup()
            }
            .ccspaceSecondaryActionButton()
            .ccspaceQuickHelp("将当前仓库配置导出为 JSON 备份")
        }
    }

    private var addRepositorySection: some View {
        HStack(spacing: 8) {
            Button {
                showAddSheet = true
            } label: {
                Label("新增仓库", systemImage: "plus")
            }
            .ccspacePrimaryActionButton()

            Spacer()
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
        CCSpaceInteractiveCard(selected: false) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(repository.repoName)
                            .font(.body.weight(.medium))

                        if let defaultBranch = repository.defaultBranch {
                            RepositoryBranchPill(title: defaultBranch, isDefault: true)
                                .ccspaceQuickHelp("默认分支")
                        }

                        let mrOnlyBranches = repository.mrTargetBranches.filter { $0 != repository.defaultBranch }
                        ForEach(mrOnlyBranches, id: \.self) { branch in
                            RepositoryBranchPill(title: branch)
                                .ccspaceQuickHelp("MR 目标分支")
                        }
                    }

                    Text(repository.gitURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button {
                        editingSheetRepository = repository
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .ccspaceIconActionButton()
                    .ccspaceQuickHelp("编辑仓库地址", providesLabel: true)

                    Button(role: .destructive) {
                        prepareDelete(repository)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .ccspaceIconActionButton()
                    .ccspaceQuickHelp("删除仓库", providesLabel: true)
                }
            }
        }
        .transition(.opacity)
    }

    private func removeRepository(_ id: UUID) {
        let repositoryName = repositoryStore.repositories.first { $0.id == id }?.repoName
        do {
            try repositoryStore.removeRepository(id: id, workplaceStore: workplaceStore)
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
}
