import SwiftUI

struct WorkplaceFormFieldsSection: View {
    let title: String
    let branchQuickHelp: String?
    @Binding var name: String
    @Binding var branch: String
    let isDisabled: Bool
    let onInputChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: title,
                subtitle: "",
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            HStack(spacing: 8) {
                TextField("工作区名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in
                        onInputChanged()
                    }

                TextField("工作分支名称", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .ccspaceQuickHelp(branchQuickHelp)
                    .onChange(of: branch) { _, _ in
                        onInputChanged()
                    }
            }
            .disabled(isDisabled)
        }
        .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
    }
}

struct WorkplaceRepositorySelectionSection: View {
    let subtitle: String
    let repositories: [WorkplaceSelectableRepository]
    let selectedIDs: Set<UUID>
    let emptySubtitle: String
    @Binding var searchText: String
    let isDisabled: Bool
    let onToggle: (UUID) -> Void

    private var presentationState: WorkplaceRepositorySelectionPresentationState {
        WorkplaceRepositorySelectionPresentationState(
            repositories: repositories,
            searchText: searchText,
            emptySubtitle: emptySubtitle
        )
    }

    private var displayedRepositories: [WorkplaceSelectableRepository] {
        WorkplaceSelectableRepositoryOrdering.prioritizeSelected(
            repositories: presentationState.filteredRepositories,
            selectedIDs: selectedIDs
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(
                title: "选择仓库",
                subtitle: subtitle,
                titleFont: .title3,
                titleWeight: .semibold,
                titleColor: .primary
            )

            if repositories.isEmpty == false {
                TextField("搜索仓库名称或地址", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
            }

            if presentationState.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: presentationState.emptyTitle,
                    subtitle: presentationState.emptySubtitle,
                    systemImage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass",
                    tint: .accentColor
                ) { EmptyView() }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(displayedRepositories) { repository in
                        WorkplaceSelectableRepositoryRow(
                            repository: repository,
                            isSelected: selectedIDs.contains(repository.id),
                            onToggle: {
                                onToggle(repository.id)
                            }
                        )
                        .disabled(isDisabled)
                    }
                }
            }
        }
        .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
    }
}

struct WorkplaceFormFooter: View {
    let submitTitle: String
    let submittingTitle: String
    let isSubmitting: Bool
    let isSubmitDisabled: Bool
    let progress: WorkplaceFormProgressPresentationState?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(progress.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(progress.countLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: progress.fractionCompleted)
                        .controlSize(.small)

                    Text(progress.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
            }

            HStack {
                Spacer()

                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .ccspaceQuickHelp(isSubmitting ? "操作进行中，请等待完成" : nil)

                Button(action: onSubmit) {
                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(submittingTitle)
                        }
                    } else {
                        Text(submitTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isSubmitDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct WorkplaceSelectableRepositoryRow: View {
    let repository: WorkplaceSelectableRepository
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            CCSpaceInteractiveCard(selected: isSelected) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.name)
                            .font(.body.weight(.medium))
                        Text(repository.url)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.name)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("切换仓库选择")
    }
}
