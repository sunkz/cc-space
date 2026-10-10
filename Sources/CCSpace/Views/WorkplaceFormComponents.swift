import SwiftUI

struct WorkplaceFormFieldsSection: View {
    let title: String
    let branchQuickHelp: String?
    @Binding var name: String
    @Binding var branch: String
    let isDisabled: Bool
    var branchValidationError: String? = nil
    var autoFocusName: Bool = false
    var nameHint: String? = nil
    var branchHint: String? = nil
    let onInputChanged: () -> Void

    @FocusState private var isNameFocused: Bool

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
        .task {
            if autoFocusName {
                try? await Task.sleep(for: .milliseconds(100))
                isNameFocused = true
            }
        }
    }
}

/// 创建/编辑弹窗列表区的共享度量(10-10 定案):可视区**最多展示 6 行**,超出内滚。
/// 行样式=线上 release 版工作区弹窗的逐行 `CCSpaceInteractiveCard`(padding 8,body 单行
/// → 卡高 32,行距 6);仓库选择列表与 MR 目标分支建议列表共用同款。
enum FormListMetrics {
    static let rowHeight: CGFloat = 32
    static let rowSpacing: CGFloat = 6
    static let maxVisibleRows = 6
    static let listMaxHeight: CGFloat =
        CGFloat(maxVisibleRows) * rowHeight + CGFloat(maxVisibleRows - 1) * rowSpacing

    /// 按实际行数取可视高度:ScrollView 在滚动轴上是贪心的,只给 `maxHeight(222)`
    /// 会让 1 行的列表也恒占 222pt,把常用链接重新推出弹窗(10-10 review P1 修复)。
    /// 行数不足 6 时高度贴合内容;超过则封顶 6 行、内部滚动。
    static func listHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let content = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * rowSpacing
        return min(content, listMaxHeight)
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

    var body: some View {
        // 展示状态与排序在每遍 body 求值只做一次:此前 `presentationState`/
        // `displayedRepositories` 是计算属性、body 内各访问多次,搜索框每按一键
        // 触发多遍 filter + prioritizeSelected(localizedStandardCompare)
        // (10-10 review P2,对齐"body 顶部求值一次沿渲染路径下发"的仓库惯例)。
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

            if state.filteredRepositories.isEmpty {
                CCSpaceEmptyStateCard(
                    title: state.emptyTitle,
                    subtitle: state.emptySubtitle,
                    systemImage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass",
                    tint: .accentColor
                ) { EmptyView() }
            } else {
                // 逐行卡片(线上 release 版样式,10-10 用户定案回退):行=CCSpaceInteractiveCard,
                // 行距 6,无外层描边容器;可视区最多 6 行内滚,高度按实际行数贴合。
                ScrollView {
                    LazyVStack(spacing: FormListMetrics.rowSpacing) {
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
                .frame(maxHeight: FormListMetrics.listHeight(rowCount: displayed.count))
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
    /// 提交中是否禁用取消。创建/编辑两个场景都传 false:克隆单仓最长 600 秒才超时,
    /// 取消按钮是唯一的即时中止通道,禁用它会配合 interactiveDismissDisabled
    /// 把用户锁死在弹窗里干等。
    var isCancelDisabledWhileSubmitting: Bool = true
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private var isCancelDisabled: Bool {
        isSubmitting && isCancelDisabledWhileSubmitting
    }

    /// 提交中且按钮可点时,语义是"中止进行中的操作并回滚",不是"关闭弹窗"。
    private var cancelTitle: String {
        isSubmitting && isCancelDisabled == false ? "中止" : "取消"
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
                .disabled(isCancelDisabled)
                .ccspaceQuickHelp(isCancelDisabled ? "操作进行中，请等待完成" : nil)

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
/// (选中 accent 淡底/hover 浅灰由卡片自带),单行仓库名 body 半粗。
/// 完整远端地址收进 ccspaceQuickHelp 悬浮提示(10-10 定案),不占副标题行。
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

                    Text(repository.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .ccspaceQuickHelp(repository.url)
        .accessibilityElement(children: .combine)
        // 地址只剩 hover 一条路径后,读屏也要能取到(10-10 review 修复)。
        .accessibilityLabel("\(repository.name)，地址 \(repository.url)")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("切换仓库选择")
    }
}
