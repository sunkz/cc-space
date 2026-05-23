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
