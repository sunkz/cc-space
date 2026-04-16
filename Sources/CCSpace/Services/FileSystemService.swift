import Foundation

protocol FileSystemServicing: Sendable {
    func createDirectory(at path: String) throws
    func removeItem(at path: String) throws
}

extension FileSystemServicing {
    func directoryExists(at path: String) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else { return false }

        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: trimmedPath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func removeItemIfExists(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try removeItem(at: path)
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
