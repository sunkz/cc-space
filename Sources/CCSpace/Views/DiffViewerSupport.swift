import Foundation

/// Diff patch 中单行的展示模型:带行号与着色分类,供 Diff 查看器渲染。
struct DiffPatchLine: Equatable {
    enum Kind: Equatable {
        /// `@@ -1,3 +1,4 @@` hunk 起始行,携带可选的函数上下文。
        case hunkHeader(context: String?)
        case added
        case removed
        case context
        /// `\ No newline at end of file` 之类的说明行。
        case note
    }

    let kind: Kind
    /// 原始行文本(含 `+`/`-`/空格前缀)。
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

/// 把 unified diff 的 patch 文本解析为可渲染的行模型。
///
/// 跳过 `diff --git` / `index` / `---` / `+++` 等元数据行,
/// 根据 `@@` hunk 头维护两侧行号计数。
enum DiffPatchLineParser {
    private static let hunkPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$"#
    )

    static func parse(_ patch: String) -> [DiffPatchLine] {
        // `"".components(separatedBy: .newlines)` 会得到一个空串元素,先排除空 patch。
        guard patch.isEmpty == false else { return [] }
        var rawLines = patch.components(separatedBy: .newlines)
        // patch 以换行结尾时切分会多出末尾空元素;它不是内容行(git 的空上下文行至少带空格前缀),
        // 若不跳过会被当作一行空上下文,渲染出幽灵空行并污染「展示所有行」的行号推进。
        if rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }
        var lines: [DiffPatchLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0

        for raw in rawLines {
            // 元数据行先于 +/- 前缀判断,避免 `--- a/...` 被当作删除行。
            if raw.hasPrefix("diff --git ") || raw.hasPrefix("index ") ||
                raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                continue
            }
            if raw.hasPrefix("@@") {
                let hunk = parseHunkHeader(raw)
                oldLineNumber = hunk.oldStart
                newLineNumber = hunk.newStart
                lines.append(DiffPatchLine(
                    kind: .hunkHeader(context: hunk.context),
                    text: raw,
                    oldLineNumber: nil,
                    newLineNumber: nil
                ))
                continue
            }
            if raw.hasPrefix("\\") {
                lines.append(DiffPatchLine(kind: .note, text: raw, oldLineNumber: nil, newLineNumber: nil))
                continue
            }
            if raw.hasPrefix("+") {
                lines.append(DiffPatchLine(
                    kind: .added,
                    text: raw,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber
                ))
                newLineNumber += 1
            } else if raw.hasPrefix("-") {
                lines.append(DiffPatchLine(
                    kind: .removed,
                    text: raw,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil
                ))
                oldLineNumber += 1
            } else {
                // 上下文行(git 用单个空格前缀,空行为空字符串)。
                lines.append(DiffPatchLine(
                    kind: .context,
                    text: raw,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber
                ))
                oldLineNumber += 1
                newLineNumber += 1
            }
        }
        return lines
    }

    /// 解析 `@@ -a,b +c,d @@ context` 形式的 hunk 头。
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int, context: String?) {
        guard let pattern = hunkPattern,
              let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else {
            return (0, 0, nil)
        }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        let context = (group(3) ?? "").trimmingCharacters(in: .whitespaces)
        return (
            Int(group(1) ?? "") ?? 0,
            Int(group(2) ?? "") ?? 0,
            context.isEmpty ? nil : context
        )
    }

    /// 解析 hunk 头两侧的起始行号(`@@ -a,b +c,d @@` 中的 a 与 c);非 hunk 头返回 nil。
    static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        guard let pattern = hunkPattern,
              let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        func group(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return Int(line[range])
        }
        guard let old = group(1), let new = group(2) else { return nil }
        return (old, new)
    }
}

/// 「展示所有行」:用文件全文把 patch 未覆盖的行补齐,得到完整文件序列的行模型。
///
/// 全文按 diff 来源取用(见 `DiffFullFileContentStrategy`):工作区改动读磁盘,
/// commit/分支对比读对应修订版本的 blob;取不到全文(删除的文件、二进制等)时不展开。
enum DiffFullFileExpander {
    /// 读工作区文件全文;文件不存在或无法按 UTF-8 解码时返回 nil。
    static func workingTreeFileContent(localPath: String, filePath: String) -> String? {
        let fullPath = (localPath as NSString).appendingPathComponent(filePath)
        return try? String(contentsOfFile: fullPath, encoding: .utf8)
    }

    /// 纯逻辑:在首个 hunk 之前、hunk 之间与最后一个 hunk 之后,补入文件全文中未被 patch 覆盖的行。
    ///
    /// 补入行的内容按新侧行号取自文件;新旧两侧行号沿 hunk 各自累计,
    /// 因此前面的 hunk 有净增/净删时,补入行的旧侧行号依然正确。
    /// patch 没有 hunk(空改动、纯重命名/权限变化)时无需展开,原样返回。
    static func expand(patchLines: [DiffPatchLine], fileContent: String?) -> [DiffPatchLine] {
        guard let fileContent else { return patchLines }
        let hunkSpans = Self.hunkSpans(in: patchLines)
        guard hunkSpans.isEmpty == false else { return patchLines }
        let fileLines = Self.contentLines(of: fileContent)

        var result: [DiffPatchLine] = []
        // 补入区间(gap)的游标:每个 gap 行在新旧两侧各消耗一行,逐行推进。
        var nextOld = 1
        var nextNew = 1
        func appendGapLines(untilNew bound: Int) {
            while nextNew < bound, nextNew - 1 < fileLines.count {
                result.append(DiffPatchLine(
                    kind: .context,
                    text: " " + fileLines[nextNew - 1],
                    oldLineNumber: nextOld,
                    newLineNumber: nextNew
                ))
                nextOld += 1
                nextNew += 1
            }
        }

        for span in hunkSpans {
            appendGapLines(untilNew: span.newStart)
            result.append(span.headerLine)
            var newCount = 0
            var oldCount = 0
            for index in span.bodyRange {
                let line = patchLines[index]
                result.append(line)
                switch line.kind {
                case .added: newCount += 1
                case .removed: oldCount += 1
                case .context: newCount += 1; oldCount += 1
                case .hunkHeader, .note: break
                }
            }
            nextNew = span.newStart + newCount
            nextOld = span.oldStart + oldCount
        }
        appendGapLines(untilNew: fileLines.count + 1)
        return result
    }

    /// 按 \n 切分并去掉行尾 \r(CRLF 不产生中间空行);末尾换行产生的空元素不属于文件内容。
    private static func contentLines(of content: String) -> [String] {
        var lines = content.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// patch 中单个 hunk 的展开信息:头行、两侧起始行号与 body 的数组下标区间(不含头行)。
    private struct HunkSpan {
        let headerLine: DiffPatchLine
        let oldStart: Int
        let newStart: Int
        let bodyRange: Range<Int>
    }

    private static func hunkSpans(in lines: [DiffPatchLine]) -> [HunkSpan] {
        struct Header {
            let index: Int
            let line: DiffPatchLine
            let oldStart: Int
            let newStart: Int
        }
        var headers: [Header] = []
        for (index, line) in lines.enumerated() {
            guard case .hunkHeader = line.kind,
                  let starts = DiffPatchLineParser.hunkStarts(line.text) else { continue }
            headers.append(Header(index: index, line: line, oldStart: starts.old, newStart: starts.new))
        }
        return headers.enumerated().map { offset, header in
            // body 到下一个 hunk 头之前为止;最后一个 hunk 的 body 到数组末尾。
            let end = offset + 1 < headers.count ? headers[offset + 1].index : lines.count
            return HunkSpan(
                headerLine: header.line,
                oldStart: header.oldStart,
                newStart: header.newStart,
                bodyRange: (header.index + 1)..<end
            )
        }
    }
}

/// 「展示所有行」新侧全文的取用策略,按 diff 来源解析。
///
/// 补全 hunk 间行的内容取自 diff 新侧:工作区改动的新侧是磁盘上的文件;
/// commit/分支对比的新侧是对应修订版本的 blob。分支对比的 head 为当前分支时,
/// diff 实为 `git diff <base>`(对比到工作区、含未提交改动),新侧仍在磁盘,
/// 必须读文件而非取 blob,否则展示的内容与 diff 对不上。
enum DiffFullFileContentStrategy: Equatable {
    /// 读磁盘上的工作区文件。
    case workingTree
    /// 读修订版本中的 blob。
    case revision(String)

    /// `head` 为 nil 的对比(detached HEAD)在加载 diff 时已报错,返回 nil 走不展开兜底。
    static func resolve(source: DiffWindowPayload.Source, currentBranch: String?) -> Self? {
        switch source {
        case .workingDirectory:
            return .workingTree
        case .commit(let hash):
            return .revision(hash)
        case .compare(_, let head):
            guard let head else { return nil }
            return head == currentBranch ? .workingTree : .revision(head)
        }
    }

    /// 取某文件的新侧全文;二进制文件不展开,返回 nil。
    func fileContent(entry: GitDiffEntry, localPath: String, gitService: GitServicing) async -> String? {
        guard entry.isBinary == false else { return nil }
        switch self {
        case .workingTree:
            return DiffFullFileExpander.workingTreeFileContent(localPath: localPath, filePath: entry.filePath)
        case .revision(let revision):
            return await gitService.blobContent(revision: revision, path: entry.filePath, in: localPath)
        }
    }
}

/// 双栏(左右)对比模式下的一行。
struct DiffSplitRow: Equatable {
    enum Content: Equatable {
        /// 整行横跨左右两栏的 hunk 头。
        case hunkHeader(DiffPatchLine)
        /// 整行横跨的说明行(如 `\ No newline at end of file`)。
        case note(DiffPatchLine)
        /// 左右配对:左为旧侧、右为新侧;上下文行两侧相同,变更块配对后不足的一侧为 nil。
        case pair(left: DiffPatchLine?, right: DiffPatchLine?)
    }

    let content: Content
}

/// 把单栏行序列按变更块配对为双栏行序列。
///
/// 连续的 removed/added 行视为一个变更块,按出现顺序两两配对成行,
/// 不足的一侧留空;上下文行两侧重复展示。
enum DiffSplitRowBuilder {
    static func rows(from lines: [DiffPatchLine]) -> [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var pendingRemoved: [DiffPatchLine] = []
        var pendingAdded: [DiffPatchLine] = []

        func flush() {
            let pairCount = max(pendingRemoved.count, pendingAdded.count)
            for index in 0..<pairCount {
                rows.append(DiffSplitRow(content: .pair(
                    left: index < pendingRemoved.count ? pendingRemoved[index] : nil,
                    right: index < pendingAdded.count ? pendingAdded[index] : nil
                )))
            }
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .added:
                pendingAdded.append(line)
            case .removed:
                pendingRemoved.append(line)
            case .context:
                flush()
                rows.append(DiffSplitRow(content: .pair(left: line, right: line)))
            case .hunkHeader:
                flush()
                rows.append(DiffSplitRow(content: .hunkHeader(line)))
            case .note:
                flush()
                rows.append(DiffSplitRow(content: .note(line)))
            }
        }
        flush()
        return rows
    }
}

/// Diff 查看器空态文案:按成因区分,避免本窗口提交成功后误显示"没有改动"。
struct DiffViewerEmptyState: Equatable {
    let title: String
    let subtitle: String

    /// 比较类空态(分支对比等双侧来源):两侧内容一致才没有差异。
    static let noChanges = DiffViewerEmptyState(title: "没有改动", subtitle: "两侧内容完全一致")
    /// 单侧来源空态(工作区未提交改动):没有待展示的改动,不存在"两侧比较"语义。
    static let noPendingChanges = DiffViewerEmptyState(title: "没有改动", subtitle: "没有待展示的改动")
    /// 单提交来源空态:该提交本身没有可展示的改动(如纯合并提交)。
    static let noCommitChanges = DiffViewerEmptyState(title: "没有改动", subtitle: "该提交没有可展示的改动")
    /// 本窗口刚提交成功,全部改动已入库。
    static let committed = DiffViewerEmptyState(title: "提交成功", subtitle: "改动已全部提交")
}

/// 依据 diff 来源与本窗口操作历史决定空态文案。
enum DiffWindowEmptyStateResolver {
    /// 仅工作区改动来源且刚在本窗口提交成功时展示"提交成功";
    /// 其余按来源区分:单侧来源(工作区改动/单提交)说"没有待展示的改动",
    /// 比较类来源(分支对比)才说"两侧内容完全一致"。
    static func resolve(source: DiffWindowPayload.Source, didCommit: Bool) -> DiffViewerEmptyState {
        if case .workingDirectory = source, didCommit {
            return .committed
        }
        switch source {
        case .workingDirectory:
            return .noPendingChanges
        case .commit:
            return .noCommitChanges
        case .compare:
            return .noChanges
        }
    }
}

/// 单文件"丢弃改动"确认弹窗的文案:按变更类型区分描述,统一强调不可恢复。
enum DiscardFileConfirmation {
    static func title(for entry: GitDiffEntry) -> String {
        "丢弃 \(entry.fileName) 的改动"
    }

    static func message(for entry: GitDiffEntry) -> String {
        switch entry.changeType {
        case .added:
            return "将删除新文件 \(entry.filePath)，此操作不可恢复。"
        case .deleted:
            return "将恢复被删除的 \(entry.filePath) 到上次提交的内容。"
        case .modified, .renamed:
            return "将丢弃对 \(entry.filePath) 的全部未提交修改，恢复到上次提交的内容，此操作不可恢复。"
        }
    }
}
