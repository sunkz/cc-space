import SwiftUI

/// Diff 查看器:展示一组文件的 unified diff,按文件分组、可折叠、带行号着色。
///
/// 以独立窗口呈现:仓库与标题集成在窗口标题栏(navigationTitle/Subtitle),
/// 文件数与折叠开关集成在工具栏;数据由父视图注入,不直接调用 GitService。
struct DiffViewerView: View {
    let repositoryName: String
    let title: String
    let diffs: [GitDiffEntry]
    let isLoading: Bool
    var error: String? = nil
    var onRetry: (() -> Void)? = nil
    /// 非 nil 时每个文件卡片展示"丢弃改动"按钮;仅工作区未提交改动来源传入,
    /// commit/分支对比等历史 diff 没有可丢弃的对象。
    var onDiscardFile: ((GitDiffEntry) -> Void)? = nil
    /// 空态文案;默认"没有改动",工作区提交成功后由调用方传入"提交成功"。
    var emptyState: DiffViewerEmptyState = .noChanges
    /// 「展示所有行」按文件取新侧全文,由调用方按来源注入(工作区来源读磁盘,
    /// commit/分支对比来源取历史 blob,见 DiffFullFileContentStrategy);
    /// 取到 nil(删除的文件、二进制等)时该文件保持仅改动行。
    /// nil 表示当前来源无法展开,该开关置灰不可用。
    var fullFileContent: (@Sendable (GitDiffEntry) async -> String?)? = nil
    /// true 时在本视图的工具栏控件前插一个 Divider:macOS 26 玻璃容器会把连续的
    /// 普通按钮并进同一颗胶囊,分隔符让 diff 控件组与前方的分支 chip 组拆开
    /// (分支比较窗口使用;独立 Diff 窗口不需要,保持单颗胶囊)。
    var toolbarLeadingSeparator = false

    /// 每个文件的展开状态,缺省值为 true(展开)。
    @State private var expandedStates: [String: Bool] = [:]

    /// 单栏/双栏对比模式;跨窗口共享并持久化。
    @AppStorage("DiffViewerView.isSplitView") private var isSplitView = false

    /// 展示文件所有行(补全 hunk 之间未更改的内容),关闭时仅展示改动行;跨窗口共享并持久化。
    @AppStorage("DiffViewerView.showAllLines") private var showAllLines = false

    /// 列表顶部锚点,折叠/展开全部后回到顶部。
    private static let listTopAnchorID = "diff-list-top"

    /// 列表外边距:顶部收紧,首卡片紧贴标题栏下方。
    private static let listPadding = EdgeInsets(top: 1, leading: 12, bottom: 12, trailing: 12)

    private func isExpanded(_ diff: GitDiffEntry) -> Bool {
        expandedStates[diff.id] ?? true
    }

    /// 「展示所有行」的提示文案(描述点击后的效果);无全文取用能力的来源不可展开。
    private var fullFileToggleHelp: String {
        if fullFileContent == nil { return "当前来源不支持展示所有行" }
        return showAllLines ? "隐藏未更改的行" : "展示所有行"
    }

    private var allExpanded: Bool {
        diffs.allSatisfy { isExpanded($0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if isLoading {
                    loadingView
                } else if let error {
                    errorView(error)
                } else if diffs.isEmpty {
                    emptyView
                } else {
                    diffList
                }
            }
            .frame(
                minWidth: 560,
                idealWidth: 720,
                maxWidth: .infinity,
                minHeight: 360,
                idealHeight: 520,
                maxHeight: .infinity
            )
            // 四个状态(加载/错误/空/列表)统一铺窗口底色,避免空态落回系统默认背景造成样式不一致。
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(repositoryName)
            .navigationSubtitle(title)
            .toolbar {
                toolbarContent(proxy: proxy)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(proxy: ScrollViewProxy) -> some ToolbarContent {
        if toolbarLeadingSeparator {
            // macOS 26 玻璃容器会把连续的普通按钮并进同一颗胶囊;ToolbarSpacer
            // 是官方间隔,让 diff 控件组与前方的分支 chip 组分成两颗胶囊。
            // Divider 实测会被并进胶囊内部,不起分隔作用。
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isLoading {
                Text("加载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 无改动时同样展示这三个按钮(置灰),保证有无改动时标题栏样式一致。
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSplitView.toggle()
                    }
                } label: {
                    Image(systemName: isSplitView ? "text.justify" : "rectangle.split.2x1")
                }
                .disabled(diffs.isEmpty)
                .ccspaceQuickHelp(isSplitView ? "切换为单栏对比" : "切换为双栏对比")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAllLines.toggle()
                    }
                } label: {
                    Image(systemName: showAllLines ? "doc.plaintext" : "doc.richtext")
                }
                .disabled(diffs.isEmpty || fullFileContent == nil)
                .ccspaceQuickHelp(fullFileToggleHelp)
                Button {
                    toggleAll(!allExpanded, proxy: proxy)
                } label: {
                    Image(systemName: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .disabled(diffs.isEmpty)
                .ccspaceQuickHelp(allExpanded ? "全部折叠" : "全部展开")
            }
        }
    }

    /// 加载中展示与最终版式同构的骨架屏,窗口打开首帧就是完整布局,数据到达后原地淡入。
    private var loadingView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    DiffFileCardSkeleton()
                }
            }
            .padding(Self.listPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text(emptyState.title)
                .font(.headline.weight(.medium))
            Text(emptyState.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("加载 diff 失败")
                .font(.headline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("重试", action: onRetry)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var diffList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.listTopAnchorID)
                ForEach(diffs) { diff in
                    DiffFileCard(
                        diff: diff,
                        isSplitView: isSplitView,
                        showAllLines: showAllLines,
                        fullFileContent: fullFileContent,
                        isExpanded: Binding(
                            get: { isExpanded(diff) },
                            set: { expandedStates[diff.id] = $0 }
                        ),
                        onDiscard: onDiscardFile.map { action in { action(diff) } }
                    )
                }
            }
            .padding(Self.listPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 全部展开或全部折叠。
    ///
    /// 批量切换会让内容总高度剧变,LazyVStack 收缩期间滚动位置会悬空、留下大片空白,
    /// 因此切换后主动动画回到顶部。
    private func toggleAll(_ expanded: Bool, proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) {
            for diff in diffs {
                expandedStates[diff.id] = expanded
            }
            proxy.scrollTo(Self.listTopAnchorID, anchor: .top)
        }
    }
}

/// 骨架屏占位块:与 CCSpaceShimmerPill 相同的呼吸动画。
private struct DiffSkeletonBlock: View {
    /// nil 表示撑满可用宽度(模拟整行内容)。
    var width: CGFloat? = nil
    var height: CGFloat = 10
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(pulse ? 0.07 : 0.035))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// 文件卡片骨架屏:与 DiffFileCard 同构,数据加载期间保持最终版式。
private struct DiffFileCardSkeleton: View {
    /// 模拟 patch 行的宽度序列(nil 表示整行)。
    private static let lineWidths: [CGFloat?] = [nil, 240, nil, 160, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DiffSkeletonBlock(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    DiffSkeletonBlock(width: 150, height: 10)
                    DiffSkeletonBlock(width: 230, height: 8)
                }
                Spacer(minLength: 8)
                DiffSkeletonBlock(width: 64, height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.lineWidths.enumerated()), id: \.offset) { _, width in
                    DiffSkeletonBlock(width: width, height: 9)
                }
            }
            .padding(12)
        }
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
}

/// 单个文件的 diff 卡片:可折叠的 header + 带行号的 patch 内容。
private struct DiffFileCard: View {
    let diff: GitDiffEntry
    let isSplitView: Bool
    let showAllLines: Bool
    /// 「展示所有行」的新侧全文取用;nil 时开关不可用。
    let fullFileContent: (@Sendable (GitDiffEntry) async -> String?)?
    @Binding var isExpanded: Bool
    /// nil 时不展示丢弃按钮(历史 diff 或未接入丢弃流程的调用方)。
    var onDiscard: (() -> Void)? = nil
    /// patch 解析结果缓存(引用类型,写入不触发视图刷新):
    /// 折叠/展开任一文件都会让兄弟卡片重算 body,不缓存则每次重跑逐行正则解析与双栏配对。
    @State private var parseMemo = PatchParseMemo()
    /// 「展示所有行」的展开结果;开关打开后惰性取全文计算一次,存 @State 驱动刷新。
    /// 取不到全文(删除的文件、二进制等)时与 patch 行一致,不会重复再取。
    @State private var expandedLines: [DiffPatchLine]?
    @State private var expandedSplitRows: [DiffSplitRow]?
    @State private var isDiscardHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.6)
                patchContent
            }
        }
        .task(id: showAllLines) {
            await expandFullFileIfNeeded()
        }
        .onChange(of: diff) { oldDiff, newDiff in
            // 聚焦刷新后同一路径带回新 patch:「展示所有行」的全文展开结果必须作废,
            // 否则开关打开时仍展示旧磁盘内容(解析行缓存由 patchHash 校验兜底)。
            guard oldDiff.patch != newDiff.patch else { return }
            expandedLines = nil
            expandedSplitRows = nil
            if showAllLines {
                // .task(id: showAllLines) 不会因 diff 变化重跑,这里主动重新取全文。
                Task { await expandFullFileIfNeeded() }
            }
        }
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: changeTypeIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(changeTypeColor)
                    .frame(width: 22, height: 22)
                    .background(changeTypeColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(diff.fileName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if diff.filePath != diff.fileName {
                        Text(diff.filePath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let onDiscard {
                    Button {
                        onDiscard()
                    } label: {
                        // 用回退箭头而非垃圾桶:丢弃改动是"恢复到上次提交",垃圾桶会误读为删除文件。
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isDiscardHovered ? Color.red : Color.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                isDiscardHovered ? Color.red.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isDiscardHovered = $0 }
                    .help("丢弃该文件的全部改动，恢复到上次提交")
                }
                statBadges
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statBadges: some View {
        if diff.isBinary {
            Text("二进制")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                statBadge("+\(diff.insertions)", tint: .green)
                statBadge("−\(diff.deletions)", tint: .red)
            }
        }
    }

    private func statBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var patchContent: some View {
        if diff.isBinary {
            Text("二进制文件,无法显示 diff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if isSplitView {
                    ForEach(Array(filteredSplitRows.enumerated()), id: \.offset) { _, row in
                        DiffSplitRowView(row: row)
                    }
                } else {
                    ForEach(Array(filteredLines.enumerated()), id: \.offset) { _, line in
                        DiffPatchLineView(line: line)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
        }
    }

    private var parsedPatch: (lines: [DiffPatchLine], splitRows: [DiffSplitRow]) {
        let patchHash = diff.patch.hashValue
        if parseMemo.cachedID == diff.id, parseMemo.cachedPatchHash == patchHash {
            return (parseMemo.lines, parseMemo.splitRows)
        }
        let lines = DiffPatchLineParser.parse(diff.patch)
        let splitRows = DiffSplitRowBuilder.rows(from: lines)
        parseMemo.cachedID = diff.id
        parseMemo.cachedPatchHash = patchHash
        parseMemo.lines = lines
        parseMemo.splitRows = splitRows
        return (lines, splitRows)
    }

    /// 「展示所有行」打开后惰性取一次全文并展开;结果存入 @State,取数只发生一次。
    /// 取不到全文时展开原样返回 patch 行,同样只取一次,不会反复发起。
    private func expandFullFileIfNeeded() async {
        guard showAllLines, expandedLines == nil, let fullFileContent else { return }
        let content = await fullFileContent(diff)
        let lines = DiffFullFileExpander.expand(patchLines: parsedPatch.lines, fileContent: content)
        expandedLines = lines
        expandedSplitRows = DiffSplitRowBuilder.rows(from: lines)
    }

    /// 根据 showAllLines 过滤后的行:开 = 全文件,关 = 仅改动行。
    /// 全文取到之前先按 patch 行展示,内容到达后自动补全(hunk 间行是在容器里追加的)。
    private var filteredLines: [DiffPatchLine] {
        if showAllLines {
            return expandedLines ?? parsedPatch.lines
        }
        return parsedPatch.lines.filter { $0.kind != .context }
    }

    /// 根据 showAllLines 过滤后的双栏行:开 = 全文件,关 = 仅改动行(hunk 头与说明行保留)。
    private var filteredSplitRows: [DiffSplitRow] {
        if showAllLines {
            if let expandedSplitRows { return expandedSplitRows }
            return parsedPatch.splitRows
        }
        return parsedPatch.splitRows.filter { row in
            switch row.content {
            case .hunkHeader, .note:
                return true
            case .pair(let left, let right):
                let leftChanged = left?.kind == .added || left?.kind == .removed
                let rightChanged = right?.kind == .added || right?.kind == .removed
                return leftChanged || rightChanged
            }
        }
    }

    private var changeTypeIcon: String {
        switch diff.changeType {
        case .added: return "plus"
        case .deleted: return "minus"
        case .renamed: return "arrow.right"
        case .modified: return "pencil"
        }
    }

    private var changeTypeColor: Color {
        switch diff.changeType {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .orange
        case .modified: return .blue
        }
    }
}

/// patch 解析结果的进程内 memo;由 DiffFileCard 以 @State 持有,实例在视图重渲染间保持稳定。
private final class PatchParseMemo {
    var cachedID: String?
    /// 缓存对应的 patch 内容哈希。diff.id 只是文件路径:聚焦刷新后同一路径
    /// 可能带回新 patch,只比对 id 会让正文停留在旧内容(header 却是新的),
    /// 用户可能基于陈旧 diff 执行「丢弃改动」造成真实丢失。
    var cachedPatchHash: Int?
    var lines: [DiffPatchLine] = []
    var splitRows: [DiffSplitRow] = []
}

/// 双栏对比的单行:hunk 头/说明行整行横跨,内容行左旧右新配对展示。
private struct DiffSplitRowView: View {
    let row: DiffSplitRow

    private var gutterWidth: CGFloat { 38 }

    var body: some View {
        switch row.content {
        case .hunkHeader(let line):
            hunkHeaderRow(line)
        case .note(let line):
            noteRow(line)
        case .pair(let left, let right):
            HStack(alignment: .top, spacing: 0) {
                DiffSplitCellView(
                    line: left,
                    lineNumber: left?.oldLineNumber,
                    background: sideBackground(left, changeKind: .removed)
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1)
                DiffSplitCellView(
                    line: right,
                    lineNumber: right?.newLineNumber,
                    background: sideBackground(right, changeKind: .added)
                )
            }
        }
    }

    private func hunkHeaderRow(_ line: DiffPatchLine) -> some View {
        HStack(spacing: 6) {
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if case .hunkHeader(let context?) = line.kind {
                Text(context)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(0.7)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .background(Color.accentColor.opacity(0.07))
        .textSelection(.enabled)
    }

    private func noteRow(_ line: DiffPatchLine) -> some View {
        Text(line.text)
            .font(.system(size: 10, design: .monospaced))
            .italic()
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, gutterWidth + 8)
            .padding(.trailing, 8)
    }

    /// 变更侧按增删着色,对侧缺失的空位给一个更弱的底色示意"此处无内容"。
    private func sideBackground(_ line: DiffPatchLine?, changeKind: DiffPatchLine.Kind) -> Color {
        guard let line else { return Color.primary.opacity(0.035) }
        if line.kind == changeKind {
            return changeKind == .removed ? .red.opacity(0.09) : .green.opacity(0.09)
        }
        return .clear
    }
}

/// 双栏对比的单侧单元格:行号 + 内容,按传入背景着色。
private struct DiffSplitCellView: View {
    let line: DiffPatchLine?
    let lineNumber: Int?
    let background: Color

    private var gutterWidth: CGFloat { 38 }

    var body: some View {
        HStack(spacing: 0) {
            Text(lineNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .background(background)
    }

    /// 去掉 +/-/空格前缀后的内容;空行渲染为单个空格。
    private var displayText: String {
        guard let line else { return "" }
        let text = String(line.text.dropFirst())
        return text.isEmpty ? " " : text
    }
}

/// 单行 diff:行号栏 + 变更符号 + 着色内容。
private struct DiffPatchLineView: View {
    let line: DiffPatchLine

    private var gutterWidth: CGFloat { 38 }
    private var signWidth: CGFloat { 14 }

    var body: some View {
        Group {
            switch line.kind {
            case .hunkHeader:
                hunkRow
            case .note:
                noteRow
            default:
                contentRow
            }
        }
        .background(rowBackground)
    }

    private var contentRow: some View {
        HStack(spacing: 0) {
            gutter(line.oldLineNumber)
            gutter(line.newLineNumber)
            sign
            content
        }
    }

    /// hunk 头占据整行,行号栏留空保持列对齐。
    private var hunkRow: some View {
        HStack(spacing: 0) {
            gutter(nil)
            gutter(nil)
            HStack(spacing: 6) {
                Text(line.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if case .hunkHeader(let context?) = line.kind {
                    Text(context)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(0.7)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
            .textSelection(.enabled)
        }
    }

    private var noteRow: some View {
        Text(line.text)
            .font(.system(size: 10, design: .monospaced))
            .italic()
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, gutterWidth * 2 + signWidth + 8)
            .padding(.trailing, 8)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 8)
    }

    @ViewBuilder
    private var sign: some View {
        Text(signSymbol)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(signColor)
            .frame(width: signWidth)
    }

    private var content: some View {
        Text(displayText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
    }

    /// 去掉 +/-/空格前缀后的内容;空行渲染为单个空格。
    private var displayText: String {
        let text = String(line.text.dropFirst())
        return text.isEmpty ? " " : text
    }

    private var signSymbol: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        default: return .clear
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .added: return .green.opacity(0.09)
        case .removed: return .red.opacity(0.09)
        case .hunkHeader: return Color.accentColor.opacity(0.07)
        default: return .clear
        }
    }
}
