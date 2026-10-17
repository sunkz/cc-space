import SwiftUI

struct WorkplaceFormFieldsSection: View {
    let title: String
    let branchQuickHelp: String?
    @Binding var name: String
    @Binding var branch: String
    let isDisabled: Bool
    var branchValidationError: String? = nil
    var nameHint: String? = nil
    var branchHint: String? = nil
    let onInputChanged: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(title: title)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("工作区名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onChange(of: name) { _, _ in
                            onInputChanged()
                        }
                    if let nameHint {
                        Text(nameHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    TextField("工作分支名称", text: $branch)
                        .textFieldStyle(.roundedBorder)
                        .ccspaceQuickHelp(branchQuickHelp)
                        .onChange(of: branch) { _, _ in
                            onInputChanged()
                        }
                    if let branchHint {
                        Text(branchHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isDisabled)

            if let branchValidationError {
                Text(branchValidationError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
        // 打开弹窗即聚焦名称框;延后一拍是等同帧布局完成,同帧设焦点会被忽略。
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isNameFocused = true
        }
    }
}

struct WorkplaceRepositorySelectionSection: View {
    let repositories: [WorkplaceSelectableRepository]
    let selectedIDs: Set<UUID>
    let emptySubtitle: String
    @Binding var searchText: String
    let isDisabled: Bool
    let onToggle: (UUID) -> Void

    var body: some View {
        // 展示状态与排序在每遍 body 求值只做一次:此前 `presentationState`/
        // `displayedRepositories` 是计算属性、body 内各访问多次,搜索框每按一键
        // 触发多遍 filter + prioritizeSelected(localizedStandardCompare)
        // (对齐"body 顶部求值一次沿渲染路径下发"的仓库惯例)。
        let state = WorkplaceRepositorySelectionPresentationState(
            repositories: repositories,
            searchText: searchText,
            emptySubtitle: emptySubtitle
        )
        let displayed = WorkplaceSelectableRepositoryOrdering.prioritizeSelected(
            repositories: state.filteredRepositories,
            selectedIDs: selectedIDs
        )
        VStack(alignment: .leading, spacing: 12) {
            CCSpaceSectionTitle(title: "选择仓库")

            if repositories.isEmpty == false {
                TextField("搜索仓库名称或地址", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
            }

            if state.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: state.emptyTitle,
                    subtitle: state.emptySubtitle,
                    systemImage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass"
                ) { EmptyView() }
            } else {
                // 逐行卡片(行=CCSpaceInteractiveCard,行距 6,无外层描边容器):
                // 全部行直接展开,不再限高内滚——长列表由弹窗外层 ScrollView 承接。
                LazyVStack(spacing: RepositoryListLayout.rowSpacing) {
                    ForEach(displayed) { repository in
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
    let progress: WorkplaceOperationProgress?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    /// 提交中按钮的语义是"中止进行中的操作并回滚",不是"关闭弹窗":克隆单仓最长
    /// 600 秒才超时,弹窗又是 interactiveDismissDisabled,取消是唯一的即时出口,
    /// 因此任何状态下都不禁用它。
    private var cancelTitle: String {
        isSubmitting ? "中止" : "取消"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                WorkplaceFormProgressPanel(progress: progress)
            }

            HStack {
                Spacer()

                Button(action: onCancel) {
                    Text(cancelTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

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
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSubmitDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.25), value: progress != nil)
    }
}

/// 进度卡片。自带 1 秒心跳,让「已进行时间」在长克隆期间走字。
///
/// 心跳挂在**只在进度存在时才出现的子视图**上:`.task` 随视图出层级自动取消,
/// 弹窗空闲(填表单)时不会产生任何周期性重渲染。
private struct WorkplaceFormProgressPanel: View {
    let progress: WorkplaceOperationProgress
    @State private var now = Date()

    var body: some View {
        let state = WorkplaceFormProgressPresentationState(progress: progress, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(state.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(state.elapsedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(state.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: state.fractionCompleted)
                .controlSize(.small)

            Text(state.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .ccspacePanel(background: .clear, cornerRadius: 12, padding: 12, borderOpacity: 0.03)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .task {
            while true {
                // 被取消(进度消失/弹窗关闭)时 sleep 抛错,心跳随之结束。
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                now = Date()
            }
        }
    }
}

/// 仓库选择行:线上 release 版样式——`CCSpaceInteractiveCard` 逐行卡片
/// (选中 accent 淡底/hover 浅灰由卡片自带),单行「仓库名 body 半粗 + 地址 caption 灰」。
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
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // 地址另起一行:与仓库名抢一行时只能截成
                        // "…/CCS…/api-g…",既看不清也点不着。
                        Text(repository.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(repository.name)，地址 \(repository.url)")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("切换仓库选择")
    }
}
