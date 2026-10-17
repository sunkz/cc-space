import Foundation

/// 解析 `git diff --numstat -p`(或 `git show --numstat -p`)为 `[GitDiffEntry]`。
/// git 先集中输出 numstat 行(`增\t删\t路径`),再集中输出 patch 段(以 `diff --git ` 起始);故分三步:收集 numstat、按 `diff --git ` 切 patch、按 header 集合消歧拼回。
enum GitDiffParser {
    static func parse(output: String) -> [GitDiffEntry] {
        let lines = output.components(separatedBy: .newlines)

        // 第一步:收集 numstat 行;路径列保留原始形式,最终路径在第三步定案(见 resolveFinalPath)。
        var stats: [(insertions: Int, deletions: Int, rawPath: String)] = []
        var patchStartIndex: Int?
        for (index, line) in lines.enumerated() {
            if let stat = parseNumstatLine(line) {
                stats.append(stat)
            } else if line.hasPrefix("diff --git ") {
                patchStartIndex = index
                break
            }
        }

        guard stats.isEmpty == false else {
            return parsePatchOnly(lines: lines)
        }

        // 第二步:以 `diff --git ` 为边界切 patch,收集 header 路径集合——header 是第三步 rename 消歧的权威依据
        // (文件名本身含 " => " 造成的误切由第三步借它纠正)。
        var patchesByPath: [String: String] = [:]
        var headerPaths: Set<String> = []
        if let startIndex = patchStartIndex {
            let knownPaths = Set(stats.map { tentativePath(rawPath: $0.rawPath) })
            var currentPath: String?
            var currentLines: [String] = []

            for line in lines[startIndex...] {
                if let path = parseDiffHeaderPath(line, knownPaths: knownPaths) {
                    if let previous = currentPath {
                        patchesByPath[previous] = currentLines.joined(separator: "\n")
                    }
                    currentPath = path
                    headerPaths.insert(path)
                    currentLines = [line]
                } else if currentPath != nil {
                    currentLines.append(line)
                }
            }
            if let last = currentPath {
                patchesByPath[last] = currentLines.joined(separator: "\n")
            }
        }

        // 第三步:按 numstat 顺序组装,路径经解码与 rename 消歧后匹配 patch。
        return stats.map { stat in
            let path = resolveFinalPath(rawPath: stat.rawPath, headerPaths: headerPaths)
            return GitDiffEntry(
                filePath: path,
                insertions: stat.insertions,
                deletions: stat.deletions,
                patch: patchesByPath[path] ?? ""
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
        // hunk 状态:header 区的 `---`/`+++` 是元数据行;进入 hunk(@@)后以 +/+++/--- 开头的都是文件内容行,必须计入增删。
        var inHunk = false

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
            inHunk = false
        }

        for line in lines {
            if let path = parseDiffHeaderPath(line, knownPaths: nil) {
                flush()
                currentPath = path
            }
            if currentPath != nil {
                currentPatch.append(line)
                if line.hasPrefix("@@") {
                    inHunk = true
                    continue
                }
                guard inHunk else { continue }
                if line.hasPrefix("+") {
                    insertions += 1
                } else if line.hasPrefix("-") {
                    deletions += 1
                }
            }
        }
        flush()

        return entries
    }

    /// 解析形如 `12\t3\tsrc/file.swift` 或 `-\t-\tbinary.png` 的 numstat 行。
    private static func parseNumstatLine(_ line: String) -> (insertions: Int, deletions: Int, rawPath: String)? {
        let cols = line.components(separatedBy: "\t")
        guard cols.count >= 3 else { return nil }
        // 计数列须为纯 ASCII 数字或 "-",且两列都校验:否则内容恰为非数字的行会被误判为 numstat(删列得到 -1、错标成二进制文件)。
        // 不能用 Character.isNumber——它按 Unicode 判定,阿拉伯-印度数字等非 ASCII 数字会让后续 Int() 失败、被误标为二进制文件。
        let addText = cols[0]
        let deleteText = cols[1]
        guard isCountField(addText), isCountField(deleteText) else { return nil }

        let insertions = Int(addText) ?? -1
        let deletions = Int(deleteText) ?? -1
        let rawPath = cols[2...].joined(separator: "\t")
        return (insertions, deletions, rawPath)
    }

    /// numstat 计数列的合法性:纯 ASCII 数字,或二进制文件的 "-" 占位。
    private static func isCountField(_ text: String) -> Bool {
        if text == "-" { return true }
        return text.isEmpty == false && text.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character($0))
        }
    }

    /// header 消歧用的初步路径:双侧引号的 rename 先切分取新侧(见 `splitDoubleQuotedRename`,否则整串解码得到含 " => " 的坏值);
    /// 单侧引号串只解码不切割(引号形式无法可靠区分 rename 压缩与字面 " => ",留给 resolveFinalPath);无引号按既有规则切 rename。
    private static func tentativePath(rawPath: String) -> String {
        if let sides = splitDoubleQuotedRename(rawPath) {
            return sides.new
        }
        guard rawPath.hasPrefix("\"") == false else { return decodeCQuotedPath(rawPath) }
        return resolveRenamePath(rawPath)
    }

    /// numstat rename 的**双侧带引号**形态 `"q1\tx.txt" => "q2\ty.txt"`:整串会被 decodeCQuotedPath 剥外层引号,得到含 ` => ` 与游离引号的坏路径、patch 匹配失败。
    /// 引用内路径自身的引号 git 必转义为 `\"`,故**未转义**引号只能是某段引用的收尾;其后紧跟 ` => "` 即两侧分界,据此切开各侧独立解码。nil = 非该形态。
    private static func splitDoubleQuotedRename(_ rawPath: String) -> (old: String, new: String)? {
        guard rawPath.hasPrefix("\""), rawPath.hasSuffix("\""), rawPath.count >= 8 else { return nil }
        let characters = Array(rawPath)
        var index = 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "\"" {
                // 第一个未转义引号 = 旧侧收尾;其后必须是 ` => "`(` => "` 后的引号是新侧起点,整串 hasSuffix `"` 已保证收尾引号存在)。
                guard index + 5 < characters.count,
                      characters[index + 1] == " ",
                      characters[index + 2] == "=",
                      characters[index + 3] == ">",
                      characters[index + 4] == " ",
                      characters[index + 5] == "\"" else { return nil }
                let oldSide = String(characters[0...index])
                let newSide = String(characters[(index + 5)...])
                return (decodeCQuotedPath(oldSide), decodeCQuotedPath(newSide))
            }
            index += 1
        }
        return nil
    }

    /// numstat 第三列最终路径定案:
    /// 1. C 引用解码:git 对含引号/反斜杠/tab/控制符/非 ASCII 的路径(core.quotepath 默认开)输出 `"wei\trd"` 引用形式,不解码则 patch 永远对不上、UI 显示原始转义;
    /// 2. 含 " => " 时借 patch header 路径集合消歧(header 权威):带引号形式默认保留整串,仅"切分结果有 header 而原串没有"时按 rename 切分
    ///    (文件名本身含 " => " 时恰是引号形式);无引号形式默认按 rename 切分,仅"原串有 header 而切分结果没有"时保留原串(无引号下 " => " 可作合法文件名);
    /// 3. header 集合为空(输出无 patch 段)时维持各自既有行为。
    private static func resolveFinalPath(rawPath: String, headerPaths: Set<String>) -> String {
        // 双侧带引号的 rename 必须先按分界切分(见 splitDoubleQuotedRename):整串解码的坏值永远匹配不上 header。
        if let sides = splitDoubleQuotedRename(rawPath) {
            return sides.new
        }
        let quoted = rawPath.hasPrefix("\"")
        let decoded = decodeCQuotedPath(rawPath)
        guard decoded.contains(" => ") else { return decoded }
        let splitPath = resolveRenamePath(decoded)
        guard splitPath != decoded else { return decoded }

        if quoted {
            if headerPaths.contains(splitPath), headerPaths.contains(decoded) == false {
                return splitPath
            }
            return decoded
        }
        if headerPaths.contains(decoded), headerPaths.contains(splitPath) == false {
            return decoded
        }
        return splitPath
    }

    /// 从 `diff --git a/path b/path` 解析 b 侧路径。git 对含空格路径的 header 不加引号,路径本身可能含 ` b/`(如 `dir b/edge.rs`),分隔符有歧义,按优先级消歧:
    /// 0. 引号形式 `diff --git "a/x" "b/y"` 先按引号解析解码;1. `knownPaths`(numstat 路径集合)唯一命中;2. 对称形式 `a/<p> b/<p>` 反推验证;3. 兜底取最后一个 ` b/` 之后。
    private static func parseDiffHeaderPath(_ line: String, knownPaths: Set<String>?) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        if let quotedPath = quotedBPath(in: line) {
            return quotedPath
        }
        // 无引号路径必不含转义序列(含反斜杠 git 必加引号),解码为恒等;防御性统一处理。
        let candidates = candidateBPaths(in: line).map(decodeCQuotedPath)
        guard candidates.isEmpty == false else {
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

    /// 从带引号 header 提取 b 侧路径并解码:定位最后一个 ` "b/`——路径内容中的引号 git 必转义为 `\"`,未转义引号只出现在段边界,取到下一未转义引号为止。
    private static func quotedBPath(in line: String) -> String? {
        guard let marker = line.range(of: " \"b/", options: .backwards) else { return nil }
        var body = ""
        var iterator = line[marker.upperBound...].makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                // 转义序列原样保留,交给 C 转义解码器统一处理。
                body.append(character)
                if let escaped = iterator.next() {
                    body.append(escaped)
                }
                continue
            }
            if character == "\"" {
                break
            }
            body.append(character)
        }
        return decodeCEscapes(body)
    }

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

    /// `git diff --no-index /dev/null file` 的 header:git 会归一化成 `diff --git a/file b/file` 故通常走主路径,此处兜底取最后一个空白分隔 token。
    private static func parseNoIndexPath(_ line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        return decodeCQuotedPath(String(parts.last!))
    }

    /// numstat rename 的三种压缩形态(返回新路径;**公共前缀必须保留**,否则与 patch header 的完整路径对不上):
    /// `old.txt => new.txt`、`src/{old.txt => new.txt}`(前缀在花括号外)、`{old.txt => new.txt}`。
    /// 两侧 C 引用各自独立(`plain name.txt => "quo\tpath"`),按 ` => ` 切分后须各侧独立解码,否则新侧带字面引号与八进制转义、patch 匹配失败。
    private static func resolveRenamePath(_ raw: String) -> String {
        guard let arrowRange = raw.range(of: " => ") else { return raw }
        let beforeArrow = raw[raw.startIndex..<arrowRange.lowerBound]
        let afterArrow = raw[arrowRange.upperBound...]
        if let braceIndex = beforeArrow.lastIndex(of: "{"), afterArrow.hasSuffix("}") {
            let prefix = String(raw[raw.startIndex..<braceIndex])
            let newSegment = String(afterArrow.dropLast())
            return decodeCQuotedPath(prefix) + decodeCQuotedPath(newSegment)
        }
        return decodeCQuotedPath(String(afterArrow))
    }

    /// 带引号路径(`"wei\trd"`)去引号并解码转义,普通路径原样返回;与 GitService.decodePorcelainPath 同一口径。
    private static func decodeCQuotedPath(_ rawPath: String) -> String {
        guard rawPath.hasPrefix("\""), rawPath.hasSuffix("\""), rawPath.count >= 2 else {
            return rawPath
        }
        return decodeCEscapes(String(rawPath.dropFirst().dropLast()))
    }

    /// 解码 C 转义:\" \\ \a \b \f \n \r \t \v 与八进制 \nnn;未知转义按字面保留,不丢内容。
    private static func decodeCEscapes(_ body: String) -> String {
        guard body.contains("\\") else { return body }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.utf8.count)
        // 索引推进而非迭代器:八进制转义不足 3 位提前结束时,迭代器版会把终止用的非数字后继字符消耗后丢弃。git 恒输出 3 位八进制,此为防御性正确。
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                continue
            }
            guard index < body.endIndex else {
                // 结尾裸反斜杠按字面量保留。
                bytes.append(UInt8(ascii: "\\"))
                continue
            }
            let escaped = body[index]
            index = body.index(after: index)
            switch escaped {
            case "\"": bytes.append(UInt8(ascii: "\""))
            case "\\": bytes.append(UInt8(ascii: "\\"))
            case "a": bytes.append(UInt8(ascii: "\u{07}"))
            case "b": bytes.append(UInt8(ascii: "\u{08}"))
            case "f": bytes.append(UInt8(ascii: "\u{0C}"))
            case "n": bytes.append(UInt8(ascii: "\n"))
            case "r": bytes.append(UInt8(ascii: "\r"))
            case "t": bytes.append(UInt8(ascii: "\t"))
            case "v": bytes.append(UInt8(ascii: "\u{0B}"))
            case let digit where ("0"..."9").contains(digit):
                var digits = String(digit)
                while digits.count < 3, index < body.endIndex, ("0"..."9").contains(body[index]) {
                    digits.append(body[index])
                    index = body.index(after: index)
                }
                if let value = UInt8(digits, radix: 8) {
                    bytes.append(value)
                } else {
                    bytes.append(contentsOf: "\\\(digits)".utf8)
                }
            default:
                bytes.append(contentsOf: "\\\(escaped)".utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
