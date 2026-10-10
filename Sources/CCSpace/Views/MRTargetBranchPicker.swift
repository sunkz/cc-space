import SwiftUI

/// 新增/编辑仓库弹窗共用的 MR 目标分支选择区:
/// 已选分支 chip 流式布局 + 搜索输入 + 远端分支建议列表。
/// 默认分支带星标且不可手动移除(由远端探测或仓库配置决定)。
struct MRTargetBranchPicker: View {
    @Binding var selectedBranches: [String]
    @Binding var inputText: String
    let suggestions: [String]
    let defaultBranch: String?
    let isLoading: Bool
    @Binding var showsSuggestions: Bool
    @FocusState.Binding var inputFocused: Bool
    /// 输入的分支名已在已选列表中时的提示(随输入变化自动消失)。
    @State private var showsDuplicateHint = false

    var body: some View {
        // 每遍 body 求值只计算一次建议列表:此前"可见性判断 + ForEach"各算一遍,
        // 每遍都对远端全量分支 filter+sort,搜索输入时是双倍主线程开销。
        let visibleSuggestions = filteredSuggestions
        VStack(alignment: .leading, spacing: 8) {
            if !selectedBranches.isEmpty {
                chipsRow
            }

            TextField("搜索或选择远端分支…", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { addMRBranch() }
                .onChange(of: inputFocused) { _, focused in
                    showsSuggestions = focused && !suggestions.isEmpty
                }
                // 聚焦状态下的输入变化保持/重开浮层:失焦收起是主通道,
                // 这里兜住"失焦后重新聚焦但 focused 值未翻转"等边角(10-10 起
                // 选中不再收起,原先为"选中后列表不再出现"打的补丁已简化)。
                .onChange(of: inputText) { _, _ in
                    showsDuplicateHint = false
                    if inputFocused {
                        showsSuggestions = true
                    }
                }
                .overlay(alignment: .trailing) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                    }
                }

            if showsDuplicateHint {
                Text("该分支已在列表中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsSuggestions, !visibleSuggestions.isEmpty {
                suggestionsList(visibleSuggestions)
            }
        }
    }

    private var chipsRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(selectedBranches, id: \.self) { branch in
                let isDefault = branch == defaultBranch
                let tint: Color = isDefault ? .orange : .accentColor
                HStack(spacing: 4) {
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                    }
                    Text(isDefault ? "\(branch) (默认)" : branch)
                        .font(.footnote)
                    if !isDefault {
                        Button {
                            selectedBranches.removeAll { $0 == branch }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除 \(branch)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(tint.opacity(0.1), in: Capsule())
                .foregroundStyle(tint)
            }
        }
    }

    private var filteredSuggestions: [String] {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [String]
        if trimmed.isEmpty {
            matched = suggestions
        } else {
            matched = suggestions.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        }
        return MRTargetBranchSuggestionOrdering.sortedSuggestions(
            matched,
            selectedBranches: selectedBranches
        )
    }

    private func suggestionsList(_ suggestions: [String]) -> some View {
        // 逐行卡片(与工作区弹窗仓库列表统一,10-10 定案):行=CCSpaceInteractiveCard,
        // 行距 6,无外层描边容器;可视区最多 6 行(FormListMetrics),超出内滚。
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FormListMetrics.rowSpacing) {
                ForEach(suggestions, id: \.self) { branch in
                    suggestionRow(branch: branch)
                }
            }
        }
        .frame(maxHeight: FormListMetrics.listMaxHeight)
    }

    private func suggestionRow(branch: String) -> some View {
        let isSelected = selectedBranches.contains(branch)
        let isDefault = branch == defaultBranch
        return Button {
            // 默认分支固定勾选,不可手动切换。
            if isDefault { return }
            if isSelected {
                selectedBranches.removeAll { $0 == branch }
            } else {
                selectedBranches.append(branch)
                // 选中后**不再收起列表**(10-10 改):旧逻辑是"浮层遮挡后续字段"时代的产物,
                // 现列表为面板内定高滚动区、不遮挡任何东西;MR 目标分支本是多选场景,
                // 选一条就收起逼用户重新聚焦才能选第二条。收起时机只保留失焦(onChange focused)。
            }
        } label: {
            // 逐行卡片(与工作区弹窗仓库行同款度量):选中/hover 底色由
            // CCSpaceInteractiveCard 自带,不再手画背景。
            CCSpaceInteractiveCard(selected: isSelected || isDefault) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected || isDefault ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected || isDefault ? Color.accentColor : .secondary)

                    Text(branch)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if isDefault {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("默认")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04), in: Capsule())
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func addMRBranch() {
        let state = MRTargetBranchAddPresentationState(
            inputText: inputText,
            existingBranches: selectedBranches
        )
        guard state.canSubmit else {
            // 重名此前是纯静默:已选分支会从建议列表里消失,回车后输入框既不清空
            // 也不报错,用户只看到"没反应"。这里给一次轻量提示。
            showsDuplicateHint = state.isDuplicate
            return
        }
        showsDuplicateHint = false
        selectedBranches.append(state.trimmedBranchName)
        inputText = ""
    }
}

/// MR 目标分支建议列表的排序规则:已选分支整体置顶,同选中级别内按分支名字典序排列。
/// 抽成纯函数便于单测;同级 tie-break 用字符串比较,避免 Swift `sorted` 不稳定
/// 导致远端列表每次求值轻微换位。
enum MRTargetBranchSuggestionOrdering {
    static func sortedSuggestions(
        _ suggestions: [String],
        selectedBranches: [String]
    ) -> [String] {
        let selectedSet = Set(selectedBranches)
        return suggestions.sorted { lhs, rhs in
            let lhsSelected = selectedSet.contains(lhs)
            let rhsSelected = selectedSet.contains(rhs)
            if lhsSelected != rhsSelected { return lhsSelected }
            return lhs < rhs
        }
    }
}

/// A simple flow layout that wraps items to the next line when they exceed available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// 单一布局计算:按给定宽度流式排布各子项尺寸,返回相对原点(0, 0)的点位与总高度。
    /// `sizeThatFits` 与 `placeSubviews` 共用,保证两者的行序完全一致。
    static func layoutPositions(
        for sizes: [CGSize],
        width: CGFloat,
        spacing: CGFloat
    ) -> (positions: [CGPoint], height: CGFloat) {
        var positions: [CGPoint] = []
        positions.reserveCapacity(sizes.count)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for size in sizes {
            if x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (positions, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 与原实现一致:nil proposal 按 0 宽处理(全部换行),保持既有自适应语义。
        let maxWidth = proposal.width ?? 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = Self.layoutPositions(for: sizes, width: maxWidth, spacing: spacing)
        return CGSize(width: maxWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = Self.layoutPositions(for: sizes, width: bounds.width, spacing: spacing)
        for (subview, position) in zip(subviews, result.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }
}
