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
                // 选中一条后 suggestionsList 会主动收起(避免遮挡后续字段);
                // macOS 上点建议行不会让 TextField 失焦,若只靠焦点变化重开,
                // 输入框保持聚焦期间列表永远不再出现,连选第二条只能先点别处。
                // 聚焦状态下的输入变化作为重开路径:清空/改动搜索词即重新浮出。
                .onChange(of: inputText) { _, _ in
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { branch in
                    suggestionRow(branch: branch)
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 250)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
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
                // 选中后立即收起建议浮层:此前只在焦点变化时更新,选中后列表一直
                // 浮在表单上方遮挡后续字段。
                showsSuggestions = false
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: isSelected || isDefault ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected || isDefault ? Color.accentColor : .secondary)
                    .padding(.leading, 10)
                    .padding(.trailing, 8)

                Text(branch)
                    .font(.body)
                    .foregroundStyle(Color.primary)

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
                    .padding(.trailing, 8)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected || isDefault ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func addMRBranch() {
        let state = MRTargetBranchAddPresentationState(
            inputText: inputText,
            existingBranches: selectedBranches
        )
        guard state.canSubmit else { return }
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
