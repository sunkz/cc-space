import Foundation

/// 「展示所有行」的全文取用与行展开(Service 层)。
///
/// 从 `Views/DiffViewerSupport.swift` 迁入:这两个类型直接读磁盘、调
/// `GitServicing.blobContent`,是业务取数而非展示逻辑。按 AGENTS.md 的依赖方向
/// (`Views → AppState/Stores → Services → Models`),git/磁盘访问不应挂在 Views 层的
/// 类型上——迁走后 View 侧只消费结果,取数入口统一到 `RepositoryWindowContext`。
/// 行为逐字保持不变。

/// 「展示所有行」:用文件全文把 patch 未覆盖的行补齐,得到完整文件序列的行模型。
///
/// 全文按 diff 来源取用(见 `DiffFullFileContentStrategy`):工作区改动读磁盘,
/// commit/分支对比读对应修订版本的 blob;取不到全文(删除的文件、二进制等)时不展开。
enum DiffFullFileExpander {
    /// 读工作区文件全文;文件不存在或无法按 UTF-8 解码时返回 nil。
    /// 同步磁盘 IO + 全文件解码,大文件可达毫秒级:必须在后台执行——
    /// 生产调用链由 fullFileContentProvider 将其包进 `Task.detached`,
    /// 勿在 MainActor 上直接调用(本函数自身是同步函数,不会自动挪线程)。
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
            // 新侧被清空的文件 git 会给 `@@ -1,3 +0,0 @@`,游标归零后补尾行会去读
            // fileLines[-1] 直接越界崩溃,故游标最低停在第 1 行。
            nextNew = max(span.newStart + newCount, 1)
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
extension DiffFullFileContentStrategy {
    /// 按 Service 层的 diff 来源解析策略。
    ///
    /// `currentBranch` 仅在比较来源下有意义:head 等于当前分支时 diff 实为
    /// `git diff <base>`(到工作区、含未提交改动),新侧在磁盘而非 blob。
    /// head 为 nil(detached HEAD)返回 nil,走"不展开"兜底。
    static func resolve(
        diffSource: RepositoryWindowContext.DiffSource,
        currentBranch: String?
    ) -> Self? {
        switch diffSource {
        case .workingDirectory:
            return .workingTree
        case .commit(let hash):
            return .revision(hash)
        case .compare(_, let head):
            guard let head else { return nil }
            return head == currentBranch ? .workingTree : .revision(head)
        }
    }
}
