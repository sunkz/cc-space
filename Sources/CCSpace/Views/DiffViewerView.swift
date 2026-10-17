import SwiftUI

struct DiffViewerView: View {
    let repositoryName: String
    let title: String
    let diffs: [GitDiffEntry]
    let isLoading: Bool
    var error: String? = nil
    var onRetry: (() -> Void)? = nil
    /// 非 nil 时每个文件卡片展示「丢弃改动」;仅工作区未提交改动来源传入,历史 diff 没有可丢弃的对象。
    var onDiscardFile: ((GitDiffEntry) -> Void)? = nil
    var emptyState: DiffViewerEmptyState
    /// 「展示所有行」按文件取新侧全文,由调用方按来源注入(见 DiffFullFileContentStrategy);
    /// 取到 nil(删除的文件、二进制等)时该文件保持仅改动行,nil 表示当前来源无法展开、开关置灰。
    var fullFileContent: (@Sendable (GitDiffEntry) async -> String?)? = nil
    /// true 时在本视图的工具栏控件前插一个 ToolbarSpacer:macOS 26 玻璃容器会把连续的
    /// 普通按钮并进同一颗胶囊(分支比较窗口需要,独立 Diff 窗口保持单颗胶囊)。
    var toolbarLeadingSeparator = false

    @State private var expandedStates: [String: Bool] = [:]

    @AppStorage("DiffViewerView.isSplitView") private var isSplitView = false

    @AppStorage("DiffViewerView.showAllLines") private var showAllLines = false

    private static let listTopAnchorID = "diff-list-top"

    private static let listPadding = EdgeInsets(top: 1, leading: 12, bottom: 12, trailing: 12)

    /// 与 `diffs` 一一对应的稳定展开键(见 `DiffExpansionKeys`)。
    /// O(n) 且要建计数字典:body 只求一次再把这个 `let` 往下传,不要让各计算属性各自算。
    private var expansionKeys: [String] {
        DiffExpansionKeys.make(for: diffs)
    }

    private func isExpanded(key: String) -> Bool {
        expandedStates[key] ?? true
    }

    private var fullFileToggleHelp: String {
        if fullFileContent == nil { return "当前来源不支持展示所有行" }
        return showAllLines ? "隐藏未更改的行" : "展示所有行"
    }

    private func allExpanded(keys: [String]) -> Bool {
        keys.allSatisfy { isExpanded(key: $0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            let keys = expansionKeys
            Group {
                if isLoading {
                    loadingView
                } else if let error {
                    errorView(error)
                } else if diffs.isEmpty {
                    emptyView
                } else {
                    diffList(keys: keys)
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
            // 四个状态(加载/错误/空/列表)统一铺窗口底色,否则空态落回系统默认背景。
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(repositoryName)
            .navigationSubtitle(title)
            .toolbar {
                toolbarContent(proxy: proxy, keys: keys)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(proxy: ScrollViewProxy, keys: [String]) -> some ToolbarContent {
        if toolbarLeadingSeparator {
            // macOS 26 玻璃容器会把连续的普通按钮并进同一颗胶囊;ToolbarSpacer 是官方间隔,
            // Divider 实测会被并进胶囊内部、不起分隔作用。
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
                // 三个按钮恒常展示、无改动时置灰,保证有无改动时标题栏样式一致。
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSplitView.toggle()
                    }
                } label: {
                    Image(systemName: isSplitView ? "text.justify" : "rectangle.split.2x1")
                }
                .disabled(diffs.isEmpty)
                .ccspaceQuickHelp(isSplitView ? "切换为单栏对比" : "切换为双栏对比", providesLabel: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAllLines.toggle()
                    }
                } label: {
                    Image(systemName: showAllLines ? "doc.plaintext" : "doc.richtext")
                }
                .disabled(diffs.isEmpty || fullFileContent == nil)
                .ccspaceQuickHelp(fullFileToggleHelp, providesLabel: true)
                Button {
                    toggleAll(!allExpanded(keys: keys), keys: keys, proxy: proxy)
                } label: {
                    Image(systemName: allExpanded(keys: keys) ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .disabled(diffs.isEmpty)
                .ccspaceQuickHelp(
                    allExpanded(keys: keys) ? "全部折叠" : "全部展开",
                    providesLabel: true
                )
            }
        }
    }

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

    private func diffList(keys: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.listTopAnchorID)
                // 视图身份也用稳定键:patch 变化不再重建卡片,@State(解析缓存、全文展开
                // 结果)得以保留,由卡片自己的 onChange 按内容作废旧值。
                ForEach(Array(zip(diffs, keys)), id: \.1) { diff, key in
                    DiffFileCard(
                        diff: diff,
                        isSplitView: isSplitView,
                        showAllLines: showAllLines,
                        fullFileContent: fullFileContent,
                        isExpanded: Binding(
                            get: { expandedStates[key] ?? true },
                            set: { expandedStates[key] = $0 }
                        ),
                        onDiscard: onDiscardFile.map { action in { action(diff) } }
                    )
                }
            }
            .padding(Self.listPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 批量切换会让内容总高度剧变,LazyVStack 收缩期间滚动位置会悬空、留下大片空白,
    /// 因此切换后主动动画回到顶部。
    private func toggleAll(_ expanded: Bool, keys: [String], proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) {
            for key in keys {
                expandedStates[key] = expanded
            }
            proxy.scrollTo(Self.listTopAnchorID, anchor: .top)
        }
    }
}

private struct DiffSkeletonBlock: View {
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

private struct DiffFileCardSkeleton: View {
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

private struct DiffFileCard: View {
    let diff: GitDiffEntry
    let isSplitView: Bool
    let showAllLines: Bool
    let fullFileContent: (@Sendable (GitDiffEntry) async -> String?)?
    @Binding var isExpanded: Bool
    var onDiscard: (() -> Void)? = nil
    /// patch 解析缓存(引用类型,写入不触发视图刷新):折叠/展开任一文件都会让兄弟卡片
    /// 重算 body,不缓存则每次重跑逐行解析与双栏配对。
    @State private var parseMemo = PatchParseMemo()
    @State private var expandedLines: [DiffPatchLine]?
    @State private var expandedSplitRows: [DiffSplitRow]?
    /// 全文展开请求的代际号:.task(id:) 与 onChange 里的裸 Task 可并发取全文,
    /// 旧 diff 的结果晚到会覆盖新结果,必须按代际落笔。
    @State private var expandGeneration = 0
    @State private var expandTask: Task<Void, Never>?
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
        .onDisappear {
            expandTask?.cancel()
            expandTask = nil
            expandGeneration += 1
        }
        .onChange(of: diff) { oldDiff, newDiff in
            // 聚焦刷新后同一路径带回新 patch:全文展开结果必须作废,否则开关打开时
            // 仍展示旧磁盘内容(解析行缓存由 patch 内容比对兜底)。
            guard oldDiff.patch != newDiff.patch else { return }
            expandedLines = nil
            expandedSplitRows = nil
            if showAllLines {
                // .task(id: showAllLines) 不会因 diff 变化重跑,这里主动重新取全文;
                // 旧请求不取消也会因代际 +1 被丢弃落笔,取消只是省一次取数。
                expandTask?.cancel()
                expandTask = Task { await expandFullFileIfNeeded() }
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
                    .accessibilityLabel("丢弃该文件的全部改动，恢复到上次提交")
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
            Text("二进制文件，无法显示 diff")
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
        if parseMemo.cachedID == diff.id {
            if parseMemo.cachedPatch == diff.patch {
                return (parseMemo.lines, parseMemo.splitRows)
            }
        }
        let lines = DiffPatchLineParser.parse(diff.patch)
        let splitRows = DiffSplitRowBuilder.rows(from: lines)
        parseMemo.cachedID = diff.id
        parseMemo.cachedPatch = diff.patch
        parseMemo.lines = lines
        parseMemo.splitRows = splitRows
        return (lines, splitRows)
    }

    /// @MainActor:体内读写 @State 并触发 memo 引用类型写入,须与主线程 body 同隔离域;
    /// 取全文的重活由注入的 provider 自己包进 `Task.detached`,本方法只 await。
    @MainActor
    private func expandFullFileIfNeeded() async {
        guard showAllLines, expandedLines == nil, let fullFileContent else { return }
        expandGeneration += 1
        let generation = expandGeneration
        let content = await fullFileContent(diff)
        // 取全文期间若有更新请求(diff 刷新/开关重开)发起,本次结果已过时,禁止落笔。
        guard generation == expandGeneration else { return }
        let patchLines = parsedPatch.lines
        // 展开与双栏配对是纯函数,单文件几万行时开销可观:放后台任务算,
        // 主线程只做代际比对与落笔。
        let expanded = await Task.detached(priority: .userInitiated) {
            () -> ([DiffPatchLine], [DiffSplitRow]) in
            let lines = DiffFullFileExpander.expand(patchLines: patchLines, fileContent: content)
            return (lines, DiffSplitRowBuilder.rows(from: lines))
        }.value
        guard generation == expandGeneration else { return }
        expandedLines = expanded.0
        expandedSplitRows = expanded.1
    }

    /// 全文取到之前先按 patch 行展示,内容到达后自动补全(hunk 间行是在容器里追加的)。
    private var filteredLines: [DiffPatchLine] {
        if showAllLines {
            return expandedLines ?? parsedPatch.lines
        }
        return parsedPatch.lines.filter { $0.kind != .context }
    }

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

private final class PatchParseMemo {
    var cachedID: String?
    /// diff.id 只是文件路径:同一路径可能带回新 patch,只比 id 会让正文停在旧内容而
    /// header 是新的,用户可能基于陈旧 diff 执行「丢弃改动」——须按内容判定命中。
    var cachedPatch: String?
    var lines: [DiffPatchLine] = []
    var splitRows: [DiffSplitRow] = []
}

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

    /// hunk 头整行横跨两栏;`text` 已含尾部函数上下文,不再另加一份。
    private func hunkHeaderRow(_ line: DiffPatchLine) -> some View {
        Text(line.text)
            .lineLimit(1)
            .truncationMode(.tail)
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

    private func sideBackground(_ line: DiffPatchLine?, changeKind: DiffPatchLine.Kind) -> Color {
        guard let line else { return Color.primary.opacity(0.035) }
        if line.kind == changeKind {
            return changeKind == .removed ? .red.opacity(0.09) : .green.opacity(0.09)
        }
        return .clear
    }
}

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

    /// hunk 头占据整行,行号栏留空保持列对齐;`text` 已含尾部函数上下文,不再另加一份。
    private var hunkRow: some View {
        HStack(spacing: 0) {
            gutter(nil)
            gutter(nil)
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.tail)
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
