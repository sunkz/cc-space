import Foundation

protocol FileSystemServicing: Sendable {
    func createDirectory(at path: String) throws
    func removeItem(at path: String) throws
}

extension FileSystemServicing {
    func directoryExists(at path: String) -> Bool {
        // 归一化口径与 LocalPathSafety.normalizedPath 一致:整串 trim 会把合法地以空格
        // 结尾的目录("mydir ")判成"不存在",磁盘刷新据此删掉记录(数据丢失)。
        // trim 结果只用于空判定,探测用原样(去前导空白后)的路径。
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return false }
        let probePath = LocalPathSafety.normalizedPath(path)
        guard probePath.isEmpty == false else { return false }

        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: probePath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func removeItemIfExists(at path: String) throws {
        do {
            try removeItem(at: path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already removed — nothing to do
        }
    }
}

struct FileSystemService: FileSystemServicing {
    func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }

    func removeItem(at path: String) throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }
}
