import Foundation

/// 解析 `git diff --numstat -p`(或 `git show --numstat -p`)的输出为 `[GitDiffEntry]`。
///
/// `git diff` 会先集中输出所有文件的 numstat 行(`增\t删\t路径`),
/// 随后再集中输出各文件的 unified diff 段落(以 `diff --git ` 行起始)。
/// 因此解析分两步:先收集 numstat 建立文件列表,再以 `diff --git ` 为边界收集 patch,
/// 最后按文件路径把 patch 拼回对应文件。
enum GitDiffParser {
    static func parse(output: String) -> [GitDiffEntry] {
        let lines = output.components(separatedBy: .newlines)

        // 第一步:收集所有 numstat 行(形如 `增\t删\t路径`)。
        var stats: [(insertions: Int, deletions: Int, path: String)] = []
        var patchStartIndex: Int?
        for (index, line) in lines.enumerated() {
            if let stat = parseNumstatLine(line) {
                stats.append(stat)
            } else if line.hasPrefix("diff --git ") {
                // 首个 patch 段落起始:numstat 区结束。
                patchStartIndex = index
                break
            }
        }

        // 没有 numstat 行:可能整个输出只有 patch(无 --numstat)。
        guard stats.isEmpty == false else {
            return parsePatchOnly(lines: lines)
        }

        // 第二步:以 `diff --git ` 行为边界,把后续输出切成每文件一段 patch。
        var patchesByPath: [String: String] = [:]
        if let startIndex = patchStartIndex {
            let knownPaths = Set(stats.map(\.path))
            var currentPath: String?
            var currentLines: [String] = []
            let flush: (inout [String: String], String?, [String]) -> Void = { map, path, patchLines in
                guard let path else { return }
                map[path] = patchLines.joined(separator: "\n")
            }

            for line in lines[startIndex...] {
                if let path = parseDiffHeaderPath(line, knownPaths: knownPaths) {
                    flush(&patchesByPath, currentPath, currentLines)
                    currentPath = path
                    currentLines = [line]
                } else if currentPath != nil {
                    currentLines.append(line)
                }
            }
            flush(&patchesByPath, currentPath, currentLines)
        }

        // 第三步:按 numstat 顺序组装结果,patch 按路径匹配。
        return stats.map { stat in
            GitDiffEntry(
                filePath: stat.path,
                insertions: stat.insertions,
                deletions: stat.deletions,
                patch: patchesByPath[stat.path] ?? ""
            )
        }
    }

    /// 仅含 patch(无 numstat)时的兜底解析:按 `diff --git ` 分段,增删数从行内容统计。
    private static func parsePatchOnly(lines: [String]) -> [GitDiffEntry] {
        var entries: [GitDiffEntry] = []
        var currentPath: String?
        var currentPatch: [String] = []
        var insertions = 0
        var deletions = 0

        func flush() {
            guard let path = currentPath else { return }
            entries.append(GitDiffEntry(
                filePath: path,
                insertions: insertions,
                deletions: deletions,
                patch: currentPatch.joined(separator: "\n")
            ))
            currentPath = nil
            currentPatch = []
            insertions = 0
            deletions = 0
        }

        for line in lines {
            if let path = parseDiffHeaderPath(line, knownPaths: nil) {
                flush()
                currentPath = path
            }
            if currentPath != nil {
                currentPatch.append(line)
                if line.hasPrefix("+") && line.hasPrefix("+++") == false {
                    insertions += 1
                } else if line.hasPrefix("-") && line.hasPrefix("---") == false {
                    deletions += 1
                }
            }
        }
        flush()

        return entries
    }

    /// 解析形如 `12\t3\tsrc/file.swift` 或 `-\t-\tbinary.png` 的 numstat 行。
    private static func parseNumstatLine(_ line: String) -> (insertions: Int, deletions: Int, path: String)? {
        let cols = line.components(separatedBy: "\t")
        guard cols.count >= 3 else { return nil }
        // 首列必须是纯 ASCII 数字或 "-",避免误把 `diff --git` 等行当 numstat;
        // 不能用 Character.isNumber——它按 Unicode 判定,会把阿拉伯-印度数字等非 ASCII
        // 数字也当合法计数列,导致后续 Int() 失败被误标为二进制文件。
        let addText = cols[0]
        let isASCIIDigits = addText.isEmpty == false && addText.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character($0))
        }
        guard isASCIIDigits || addText == "-" else { return nil }

        let insertions = Int(addText) ?? -1
        let deletions = Int(cols[1]) ?? -1
        // 路径列可能含 rename 的 `old => new` 形式,取 `=>` 之后或原值。
        let rawPath = cols[2...].joined(separator: "\t")
        let path = resolveRenamePath(rawPath)
        return (insertions, deletions, path)
    }

    /// 从 `diff --git a/path b/path` 行解析出文件路径(取 b/ 之后的路径)。
    ///
    /// git 对含空格路径的 header 不加引号,路径本身可能含 ` b/` 子串
    /// (如 `dir b/edge.rs`),因此分隔符有歧义,按以下优先级消歧:
    /// 1. `knownPaths` 是第一步解析出的 numstat 路径集合,能唯一命中真实 b 侧路径;
    /// 2. 对称形式 `a/<p> b/<p>`(普通修改)成立时,路径可反推验证;
    /// 3. 兜底取最后一个 ` b/` 之后的部分。
    private static func parseDiffHeaderPath(_ line: String, knownPaths: Set<String>?) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        let candidates = candidateBPaths(in: line)
        guard candidates.isEmpty == false else {
            // 可能是 `diff --git a/file b/file` 之外的形式(如 --no-index 的 /dev/null)。
            return parseNoIndexPath(line)
        }

        if let knownPaths, let matched = candidates.first(where: { knownPaths.contains($0) }) {
            return matched
        }
        for candidate in candidates where line == "diff --git a/\(candidate) b/\(candidate)" {
            return candidate
        }
        return candidates.last
    }

    /// 枚举 header 行中所有 ` b/` 出现位置对应的候选 b 侧路径(按出现先后排序)。
    private static func candidateBPaths(in line: String) -> [String] {
        var candidates: [String] = []
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(of: " b/", range: searchStart..<line.endIndex) {
            candidates.append(String(line[range.upperBound...]))
            searchStart = line.index(after: range.lowerBound)
        }
        return candidates
    }

    /// 处理 `git diff --no-index /dev/null file` 产生的特殊 header。
    /// 其格式为 `diff --git a/file b/file`(git 会归一化),故通常走主路径;
    /// 此处作为兜底取最后一个空白分隔的 token。
    private static func parseNoIndexPath(_ line: String) -> String? {
        let parts = line.split(separator: " ")
        // `diff --git a/<x> b/<y>` 至少 4 段;取最后一段。
        guard parts.count >= 4 else { return nil }
        return String(parts.last!)
    }

    /// 处理 rename 的压缩路径形式,返回新路径。git 有三种输出形态:
    /// - `old.txt => new.txt`(无公共前缀,两侧都是完整路径)
    /// - `src/{old.txt => new.txt}`(公共前缀在花括号外,须保留)
    /// - `{old.txt => new.txt}`(整个变化的路径在花括号内)
    /// 公共前缀必须保留,否则与 patch header 的完整路径对不上。
    ///
    /// numstat 路径列没有 `R` 状态前缀可确认 rename,但 git 对含空格等特殊字符的
    /// 路径必输出带引号形式(未加 `-z` 时),而未引号路径中的 " => " 只会来自
    /// rename 压缩形式(含 `--no-index` 的 `/dev/null => file`)——因此带引号的路径
    /// 原样返回,不再按 rename 切割,避免文件名本身含 " => " 时被误切。
    private static func resolveRenamePath(_ raw: String) -> String {
        guard raw.hasPrefix("\"") == false else { return raw }
        guard let arrowRange = raw.range(of: " => ") else { return raw }
        let beforeArrow = raw[raw.startIndex..<arrowRange.lowerBound]
        let afterArrow = raw[arrowRange.upperBound...]
        if let braceIndex = beforeArrow.lastIndex(of: "{"), afterArrow.hasSuffix("}") {
            return String(raw[raw.startIndex..<braceIndex]) + String(afterArrow.dropLast())
        }
        return String(afterArrow)
    }
}
