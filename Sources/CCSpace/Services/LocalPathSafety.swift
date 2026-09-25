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

enum LocalPathSafety {
    static func normalizedPath(_ path: String) -> String {
        // trim 结果只用于"是否为空"的判断;真实路径原样传递——
        // 目录名本身可以合法地以空格结尾(如误建的 "mydir "),trim 会把它改写成另一个路径。
        // 仅去掉**前导**空白:前导空白会让相对/绝对路径判定出错(整串被当相对路径拼接 cwd),
        // 而"以空格开头且紧随绝对路径"的输入几乎必然是用户粘贴时的杂质。
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return "" }
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

    static func validateManagedPath(
        _ path: String,
        within rootPath: String
    ) throws {
        guard isWithinDirectory(path, rootPath: rootPath) else {
            throw LocalPathSafetyError.unsafeManagedPath
        }
    }

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
