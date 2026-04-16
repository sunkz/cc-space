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
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return "" }
        return URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
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
              trimmedComponent.contains("/") == false else {
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
        return normalizedChildPath == normalizedRootPath ||
            normalizedChildPath.hasPrefix(normalizedRootPath + "/")
    }
}
