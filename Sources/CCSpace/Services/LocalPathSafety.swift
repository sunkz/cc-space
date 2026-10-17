import Foundation

enum LocalPathSafetyError: LocalizedError, Equatable {
    case invalidComponent(fieldName: String)
    case unsafeManagedPath

    var errorDescription: String? {
        switch self {
        case .invalidComponent(let fieldName):
            return "\(fieldName)不能包含路径分隔符，且不能为 . 或 .."
        case .unsafeManagedPath:
            return "检测到异常的本地路径，请先检查工作区配置"
        }
    }
}

/// TOCTOU 边界:本类型全部校验与规范化都是**时点快照**——通过的瞬间文件系统状态并未被冻结,符号链接随后
/// 可能被替换、目录可能被改名/删除/重建;破坏性操作(删除、移动、覆盖写)必须紧邻执行前重新校验。
enum LocalPathSafety {
    /// 锁互斥 key:去前导空白 + 标准化 + 解析符号链接 + 统一小写;取向**宁可过度加锁不可漏锁**
    /// (原始串作 key 时 trailing slash/大小写/symlink 别名会让同一物理目录拿到两把锁,互斥被绕过)。
    /// key 取决于调用瞬间的磁盘状态,acquire/release 不得各自独立推导(见 `RepositoryOperationLock` 的 raw→key 映射)。
    static func canonicalLockKey(for path: String) -> String {
        let normalized = normalizedPath(path)
        guard normalized.isEmpty == false else { return normalized }
        return resolvedRealPath(of: normalized).lowercased()
    }

    static func normalizedPath(_ path: String) -> String {
        // trim 结果只用于"是否为空"的判断,真实路径原样传递:目录名可合法以空格结尾,trim 会改写成另一个路径。
        // 仅去掉**前导**空白:前导空白会让整串被当作相对路径拼接 cwd,而"空格开头+绝对路径"几乎都是粘贴杂质。
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return "" }
        // NUL 字节进 argv 会在 C 字符串桥接处 fatalError 崩进程(几乎必然来自被手工篡改的 JSON 配置);
        // 按"非法路径"归一为空串,让所有调用点现有的 isEmpty 防御统一转为拒绝。
        guard trimmedPath.contains("\0") == false else { return "" }
        // 相对路径一律拒绝:锚点是**本进程的当前工作目录**,对 GUI app 是未定义值且可能随环境漂移——
        // 同一份配置两次启动归一成不同路径,锁 key 随之变化,containment 判定形同虚设。
        guard trimmedPath.hasPrefix("/") else { return "" }
        let leadingTrimmed = String(path.drop(while: { $0 == " " || $0 == "\t" || $0.isNewline }))
        return URL(fileURLWithPath: leadingTrimmed).standardizedFileURL.path
    }

    static func validateComponent(
        _ component: String,
        fieldName: String
    ) throws -> String {
        let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedComponent.isEmpty == false else {
            throw LocalPathSafetyError.invalidComponent(fieldName: fieldName)
        }
        guard trimmedComponent != ".",
              trimmedComponent != "..",
              trimmedComponent.contains("/") == false,
              trimmedComponent.contains("\0") == false,
              trimmedComponent.contains(":") == false else {
            throw LocalPathSafetyError.invalidComponent(fieldName: fieldName)
        }
        return trimmedComponent
    }

    /// TOCTOU:返回值只代表校验时刻;随后对返回路径做破坏性操作前必须重新校验(符号链接可能在期间被替换)。
    static func childPath(
        in parentPath: String,
        component: String,
        fieldName: String
    ) throws -> String {
        let normalizedParentPath = normalizedPath(parentPath)
        guard normalizedParentPath.isEmpty == false else {
            throw LocalPathSafetyError.unsafeManagedPath
        }

        let validatedComponent = try validateComponent(
            component,
            fieldName: fieldName
        )
        let childPath = URL(fileURLWithPath: normalizedParentPath)
            .appendingPathComponent(validatedComponent)
            .standardizedFileURL
            .path

        try validateManagedPath(childPath, within: normalizedParentPath)
        return childPath
    }

    /// TOCTOU:通过仅代表校验瞬间的磁盘状态,中途的符号链接替换或目录改名会使旧结论失效;
    /// 删除/移动等破坏性操作前必须紧邻操作重新调用本方法。
    static func validateManagedPath(
        _ path: String,
        within rootPath: String
    ) throws {
        guard isWithinDirectory(path, rootPath: rootPath) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }
    }

    /// 严格包含:不把"等于根"算作根内。破坏性操作(递归删除、整树移动)必须用本判定而非 `isWithinDirectory`,
    /// 否则记录路径被手工编辑成恰好等于受管根时,`rm -rf <root>` 会把整棵受管根(含其它工作区)一并删掉。
    static func isStrictlyWithinDirectory(
        _ path: String,
        rootPath: String
    ) -> Bool {
        guard isWithinDirectory(path, rootPath: rootPath) else { return false }
        let normalizedChildPath = normalizedPath(path)
        let normalizedRootPath = normalizedPath(rootPath)
        guard normalizedChildPath.isEmpty == false,
              normalizedRootPath.isEmpty == false else {
            return false
        }
        let resolvedChild = resolvedRealPath(of: normalizedChildPath)
        let resolvedRoot = resolvedRealPath(of: normalizedRootPath)
        // 大小写归一并排除:isWithinDirectory 走大小写不敏感分支放行时,两者本就指向同一目录,不算严格包含。
        return resolvedChild != resolvedRoot
            && resolvedChild.lowercased() != resolvedRoot.lowercased()
    }

    /// 破坏性操作的 containment 校验入口:`path` 必须**严格位于** `rootPath` 之下;TOCTOU 契约同 `validateManagedPath`。
    static func validateStrictlyContainedPath(
        _ path: String,
        within rootPath: String
    ) throws {
        guard isStrictlyWithinDirectory(path, rootPath: rootPath) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }
    }

    /// containment 判定入口:两端先归一化 + 解析符号链接,再比较词法前缀。
    /// TOCTOU:解析出的"真实位置"随磁盘状态变化,结论只在调用时刻成立;破坏性操作前须重新校验。
    static func isWithinDirectory(
        _ path: String,
        rootPath: String
    ) -> Bool {
        let normalizedChildPath = normalizedPath(path)
        let normalizedRootPath = normalizedPath(rootPath)
        guard normalizedChildPath.isEmpty == false,
              normalizedRootPath.isEmpty == false else {
            return false
        }
        // 悬空符号链接(链接在、目标不在)必须直接判越界:resolvingSymlinksInPath 解析不了它(实测原样返回),
        // 它会被当成"不存在的尾部"词法拼回、按"根内"放行,待外部进程把目标落地后克隆/删除就物理落在根外。
        guard hasDanglingSymlink(in: normalizedChildPath) == false else { return false }
        // 纵深防御:纯词法前缀比较挡不住"中间符号链接"逃逸(根内指向根外的 symlink 目录),故两端都先解析符号链接。
        let resolvedChild = resolvedRealPath(of: normalizedChildPath)
        let resolvedRoot = resolvedRealPath(of: normalizedRootPath)
        return isPathPrefix(resolvedRoot, of: resolvedChild)
    }

    /// 前缀比较默认**严格区分大小写**:无条件放宽在大小写敏感卷上 fail-open(受管根 `/A/ws` 会把物理无关的
    /// 兄弟目录 `/a/ws/x` 判为"根内",删除/pull 直接作用在未受管目录上);只有确认卷不支持大小写敏感文件名才放宽。
    private static func isPathPrefix(_ prefix: String, of path: String) -> Bool {
        if path == prefix { return true }
        if path.hasPrefix(prefix + "/") { return true }
        return hasCaseInsensitivePathPrefix(prefix, path) && volumeMayBeCaseInsensitive(atPath: prefix)
    }

    /// 路径任一**已存在**组件是否为悬空符号链接。判定必须用 lstat:`fileExists` 跟随链接,悬空链接反而报
    /// "不存在",于是被 `resolvedRealPath` 当成缺失尾部原样词法拼回,containment 因此误判"根内"。
    static func hasDanglingSymlink(in path: String) -> Bool {
        var prefix = "/"
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        for component in components {
            prefix = URL(fileURLWithPath: prefix).appendingPathComponent(component).path
            var entryInfo = stat()
            guard lstat(prefix, &entryInfo) == 0 else {
                // 该级不存在:其后各级也必然不存在,不存在的东西不构成悬空链接。
                return false
            }
            guard (entryInfo.st_mode & S_IFMT) == S_IFLNK else { continue }
            var targetInfo = stat()
            if stat(prefix, &targetInfo) != 0 { return true }
        }
        return false
    }

    private static func hasCaseInsensitivePathPrefix(_ prefix: String, _ path: String) -> Bool {
        let loweredPath = path.lowercased()
        let loweredPrefix = prefix.lowercased()
        return loweredPath == loweredPrefix || loweredPath.hasPrefix(loweredPrefix + "/")
    }

    /// 该路径所在卷是否**可能**大小写不敏感。查询失败时**有意按"可能"处理**(fail-open):属环境异常,
    /// 沿用既有放宽,避免把默认卷上的合法受管路径误判越界。
    private static func volumeMayBeCaseInsensitive(atPath path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let supportsCaseSensitive = values?.volumeSupportsCaseSensitiveNames else { return true }
        return supportsCaseSensitive == false
    }

    /// `URL.resolvingSymlinksInPath` 只在**整条路径都存在**时才解析符号链接(尚未落盘时原样返回),
    /// 因此逐级向上找最长存在的祖先做解析,再把不存在的尾部组件原样拼回。
    private static func resolvedRealPath(of path: String) -> String {
        let fileManager = FileManager.default
        var missingComponents: [String] = []
        var current = path
        while fileManager.fileExists(atPath: current) == false {
            let currentURL = URL(fileURLWithPath: current)
            let lastComponent = currentURL.lastPathComponent
            guard lastComponent != "/", currentURL.pathComponents.count > 1 else { break }
            missingComponents.insert(lastComponent, at: 0)
            current = currentURL.deletingLastPathComponent().path
        }
        var resolved = URL(fileURLWithPath: current).resolvingSymlinksInPath().path
        for component in missingComponents {
            resolved = URL(fileURLWithPath: resolved).appendingPathComponent(component).path
        }
        return resolved
    }
}
