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

/// 本地路径安全防线:路径组件校验、受管路径 containment 检查与锁互斥 key 规范化。
///
/// ## TOCTOU 边界(重要)
/// 本类型提供的全部校验与规范化都是**时点快照**:校验通过的瞬间,文件系统状态
/// 并未被冻结——路径上的符号链接随后可能被替换、目录可能被改名/删除/重建,
/// 其他进程也可能并发改写。校验通过不构成任何持续性保证。
/// 敏感消费方(删除、移动、覆盖写等破坏性文件系统操作)必须在**紧邻破坏性操作
/// 执行前**重新校验(re-validate immediately before the destructive operation),
/// 不能依赖更早时点(如配置加载、UI 提交时)的校验结论。
enum LocalPathSafety {
    /// 锁互斥用的规范化 key:去前导空白 + 标准化 + 解析符号链接 + 统一小写。
    ///
    /// `RepositoryOperationLock` 此前以**未归一化的原始字符串**为 key:trailing slash、
    /// 大小写、symlink 别名都会让同一物理目录拿到两把"不同"的锁,互斥保证被绕过,
    /// 与 `isWithinDirectory` 刻意做 symlink/大小写归一化的立场自相矛盾。
    /// 设计取向是**宁可过度加锁不可漏锁**:在大小写敏感卷上把不同目录折成同一 key
    /// 只会串行化两个操作(慢一点),而漏锁会让并发 git 写操作交错损坏仓库。
    ///
    /// TOCTOU:结果取决于调用瞬间的磁盘状态(symlink 解析、缺失尾部重建),
    /// 同一字符串在磁盘形态变化前后可能得到不同 key——因此锁的 acquire/release
    /// 不得各自独立推导(见 `RepositoryOperationLock` 的 raw→key 映射)。
    static func canonicalLockKey(for path: String) -> String {
        let normalized = normalizedPath(path)
        guard normalized.isEmpty == false else { return normalized }
        return resolvedRealPath(of: normalized).lowercased()
    }

    static func normalizedPath(_ path: String) -> String {
        // trim 结果只用于"是否为空"的判断;真实路径原样传递——
        // 目录名本身可以合法地以空格结尾(如误建的 "mydir "),trim 会把它改写成另一个路径。
        // 仅去掉**前导**空白:前导空白会让相对/绝对路径判定出错(整串被当相对路径拼接 cwd),
        // 而"以空格开头且紧随绝对路径"的输入几乎必然是用户粘贴时的杂质。
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return "" }
        // NUL 字节:进 argv 会在 C 字符串桥接处 fatalError 崩进程(macOS 文件名唯一
        // 的非法字节,出现在路径里几乎必然来自被手工篡改的 JSON 配置)。按"非法路径"
        // 归一为空串,让所有调用点现有的 isEmpty 防御统一转为拒绝。
        guard trimmedPath.contains("\0") == false else { return "" }
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

    /// 拼接受管子路径并校验 containment。
    ///
    /// TOCTOU:返回值只代表校验时刻的结论;随后对返回路径做破坏性操作前,
    /// 敏感消费方必须重新校验(符号链接可能在期间被替换、目录可能被改名)。
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

    /// 校验 `path` 位于 `rootPath` 之内(受管路径 containment 检查)。
    ///
    /// TOCTOU:通过仅代表校验瞬间的磁盘状态;在删除/移动等破坏性操作前必须
    /// 紧邻操作重新调用本方法,中间的符号链接替换或目录改名会使旧结论失效。
    static func validateManagedPath(
        _ path: String,
        within rootPath: String
    ) throws {
        guard isWithinDirectory(path, rootPath: rootPath) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }
    }

    /// containment 判定入口:两端先做归一化 + 符号链接解析,再比较词法前缀。
    ///
    /// TOCTOU:解析出的"真实位置"随磁盘状态变化,结论只在调用时刻成立,
    /// 不冻结文件系统;破坏性操作前须重新校验(见类型级 TOCTOU 注释)。
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
        // 纵深防御:纯词法前缀比较挡不住"中间符号链接"逃逸——
        // 工作区根内若有指向根外的 symlink 目录,其下的"受管路径"词法上合法、物理上在根外。
        // 因此对参与比较的两端先解析符号链接,再比较。
        let resolvedChild = resolvedRealPath(of: normalizedChildPath)
        let resolvedRoot = resolvedRealPath(of: normalizedRootPath)
        return isPathPrefix(resolvedRoot, of: resolvedChild)
    }

    /// 前缀比较:macOS 默认卷大小写不敏感,仅大小写不同的两个路径指向同一目录,
    /// 严格区分大小写会把合法受管路径误判为越界(fail-closed 用错了方向)。
    private static func isPathPrefix(_ prefix: String, of path: String) -> Bool {
        let loweredPath = path.lowercased()
        let loweredPrefix = prefix.lowercased()
        if loweredPath == loweredPrefix { return true }
        return loweredPath.hasPrefix(loweredPrefix + "/")
    }

    /// 解析路径的真实位置:URL.resolvingSymlinksInPath 只在**整条路径都存在**时
    /// 才解析符号链接(新建工作区/文件尚未落盘时原样返回),因此逐级向上找到
    /// 最长存在的祖先做解析,再把不存在的尾部组件原样拼回。
    private static func resolvedRealPath(of path: String) -> String {
        let fileManager = FileManager.default
        var missingComponents: [String] = []
        var current = path
        while fileManager.fileExists(atPath: current) == false {
            let currentURL = URL(fileURLWithPath: current)
            let lastComponent = currentURL.lastPathComponent
            // 已到根目录,无法继续上溯。
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
