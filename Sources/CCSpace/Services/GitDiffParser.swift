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

        // 第一步:收集所有 numstat 行(形如 `增\t删\t路径`),路径列保留原始形式;
        // 最终路径在拿到 patch header 路径集合后再定(见 resolveFinalPath)。
        var stats: [(insertions: Int, deletions: Int, rawPath: String)] = []
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

        // 第二步:以 `diff --git ` 行为边界,把后续输出切成每文件一段 patch,
        // 同时收集 header 解析出的路径集合(第三步 rename 消歧的权威依据)。
        // header 消歧仍用 numstat 的初步路径(按既有 rename 规则切分 + C 转义解码);
        // 文件名本身含 " => " 造成的误切由第三步借 header 集合纠正。
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

        // 第三步:按 numstat 顺序组装结果,路径经解码与 rename 消歧后匹配 patch。
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
        // hunk 状态:`---`/`+++` 只在 hunk 之前的 header 区属于元数据行;
        // 进入 hunk(@@ 行)后,以 +/+++/--- 开头的都是文件内容行,必须计入增删
        // (内容本身以 "+++" 开头的行在 diff 中就是 "+++",此前被误排除)。
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
        // 计数列必须是纯 ASCII 数字或 "-",避免误把 `diff --git` 等行当 numstat;
        // 两列都校验:二进制文件两列均为 "-",单列缺失校验会把内容恰为非数字的
        // 行误判为 numstat(删列得到 -1,被错标成二进制文件)。
        // 不能用 Character.isNumber——它按 Unicode 判定,会把阿拉伯-印度数字等非 ASCII
        // 数字也当合法计数列,导致后续 Int() 失败被误标为二进制文件。
        let addText = cols[0]
        let deleteText = cols[1]
        guard isCountField(addText), isCountField(deleteText) else { return nil }

        let insertions = Int(addText) ?? -1
        let deletions = Int(deleteText) ?? -1
        // 路径列保留原始形式(可能带 C 引号、可能含 rename 的 `old => new` 压缩形式),
        // 由 resolveFinalPath 统一定案。
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

    /// header 消歧用的初步路径:带引号的先解码(不按 rename 切割——引号形式无法
    /// 可靠区分 rename 压缩与字面 " => ",留给 resolveFinalPath 借 header 集合消歧);
    /// 无引号的按既有规则切分 rename 压缩形式。
    private static func tentativePath(rawPath: String) -> String {
        guard rawPath.hasPrefix("\"") == false else { return decodeCQuotedPath(rawPath) }
        return resolveRenamePath(rawPath)
    }

    /// numstat 第三列的最终路径定案:
    /// 1. C 引用解码:git 对含引号/反斜杠/tab/控制符/非 ASCII(core.quotepath 默认开)
    ///    的路径输出 `"wei\trd"` 引用形式,不解码则 patch 永远对不上、UI 显示原始转义;
    /// 2. 含 " => " 时按 rename 压缩形式切分,但借 patch header 路径集合消歧——
    ///    header 是权威:带引号路径仅在"切分结果有 header 而原串没有"时按 rename 切分
    ///    (git 对特殊字符路径必加引号,文件名本身含 " => " 时恰是引号形式);
    ///    无引号路径相反,默认 " => " 是 rename 压缩形式,仅当"原串有 header 而
    ///    切分结果没有"时保留原串(文件名本身含 " => ",无引号时合法);
    /// 3. header 集合为空(输出无 patch 段)时维持各自既有行为。
    private static func resolveFinalPath(rawPath: String, headerPaths: Set<String>) -> String {
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

    /// 从 `diff --git a/path b/path` 行解析出文件路径(取 b/ 之后的路径)。
    ///
    /// git 对含空格路径的 header 不加引号,路径本身可能含 ` b/` 子串
    /// (如 `dir b/edge.rs`),因此分隔符有歧义,按以下优先级消歧:
    /// 0. 带引号形式 `diff --git "a/x" "b/y"`(git 对特殊字符路径整体加引号),
    ///    普通 ` b/` 扫描取不到路径,先按引号形式解析并解码;
    /// 1. `knownPaths` 是第一步解析出的 numstat 路径集合,能唯一命中真实 b 侧路径;
    /// 2. 对称形式 `a/<p> b/<p>`(普通修改)成立时,路径可反推验证;
    /// 3. 兜底取最后一个 ` b/` 之后的部分。
    private static func parseDiffHeaderPath(_ line: String, knownPaths: Set<String>?) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        if let quotedPath = quotedBPath(in: line) {
            return quotedPath
        }
        // 无引号路径不会含转义序列(含反斜杠必被加引号),解码为恒等;防御性统一处理。
        let candidates = candidateBPaths(in: line).map(decodeCQuotedPath)
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

    /// 从带引号形式的 header 提取 b 侧路径并解码:`diff --git "a/x" "b/y"`。
    /// 定位最后一个 ` "b/`(未转义引号只会出现在路径段边界,路径内容中的引号
    /// 会被转义为 \",不会形成该标记),标记本身已消费 `b/` 前缀,
    /// 取内容到下一个未转义引号为止后解码。
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
        return decodeCQuotedPath(String(parts.last!))
    }

    /// 处理 rename 的压缩路径形式(输入已解码),返回新路径。git 有三种输出形态:
    /// - `old.txt => new.txt`(无公共前缀,两侧都是完整路径)
    /// - `src/{old.txt => new.txt}`(公共前缀在花括号外,须保留)
    /// - `{old.txt => new.txt}`(整个变化的路径在花括号内)
    /// 公共前缀必须保留,否则与 patch header 的完整路径对不上。
    private static func resolveRenamePath(_ raw: String) -> String {
        guard let arrowRange = raw.range(of: " => ") else { return raw }
        let beforeArrow = raw[raw.startIndex..<arrowRange.lowerBound]
        let afterArrow = raw[arrowRange.upperBound...]
        if let braceIndex = beforeArrow.lastIndex(of: "{"), afterArrow.hasSuffix("}") {
            return String(raw[raw.startIndex..<braceIndex]) + String(afterArrow.dropLast())
        }
        return String(afterArrow)
    }

    /// 解码 git 的 C 引用路径:带引号形式(`"wei\trd"`)去引号并解码转义序列,
    /// 普通路径原样返回。与 GitService.decodePorcelainPath 同一口径。
    private static func decodeCQuotedPath(_ rawPath: String) -> String {
        guard rawPath.hasPrefix("\""), rawPath.hasSuffix("\""), rawPath.count >= 2 else {
            return rawPath
        }
        return decodeCEscapes(String(rawPath.dropFirst().dropLast()))
    }

    /// 解码 C 转义序列:\" \\ \a \b \f \n \r \t \v 与八进制 \nnn;
    /// 未知转义按字面保留,不丢内容。
    private static func decodeCEscapes(_ body: String) -> String {
        guard body.contains("\\") else { return body }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.utf8.count)
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                continue
            }
            guard let escaped = iterator.next() else {
                // 结尾裸反斜杠:按字面量保留,不丢内容。
                bytes.append(UInt8(ascii: "\\"))
                continue
            }
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
                // 八进制 \NNN(N 最多 3 位)。
                var digits = String(digit)
                while digits.count < 3, let next = iterator.next(), ("0"..."9").contains(next) {
                    digits.append(next)
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
