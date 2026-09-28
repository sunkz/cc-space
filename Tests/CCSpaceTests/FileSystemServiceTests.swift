import XCTest
@testable import CCSpace

/// FileSystemService 及 FileSystemServicing 默认扩展的真实行为测试:
/// 全部在 NSTemporaryDirectory 下的唯一临时根中进行,用例结束即清理。
final class FileSystemServiceTests: XCTestCase {
    func test_createDirectory_createsIntermediateDirectoriesAndToleratesExisting() throws {
        let root = try makeFileSystemTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileSystemService()

        let nested = root.appendingPathComponent("workspace/repo/sub", isDirectory: true)
        try service.createDirectory(at: nested.path)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        // 目录已存在时重复创建不应抛错(withIntermediateDirectories 语义)。
        XCTAssertNoThrow(try service.createDirectory(at: nested.path))
    }

    func test_removeItem_deletesEntireDirectoryTree() throws {
        let root = try makeFileSystemTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileSystemService()

        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try service.createDirectory(at: inner.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.path))

        try service.removeItem(at: outer.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inner.path))
    }

    func test_removeItemIfExists_swallowsOnlyNoSuchFileError() throws {
        // 底层抛 NSFileNoSuchFileError:视为已被删除,静默吞掉。
        let missingStub = StubbedFileSystemStub(
            removeErrorDomain: NSCocoaErrorDomain,
            removeErrorCode: NSFileNoSuchFileError
        )
        XCTAssertNoThrow(try missingStub.removeItemIfExists(at: "/no/such/path"))

        // 其他错误必须原样上抛,不能被误吞。
        let deniedStub = StubbedFileSystemStub(
            removeErrorDomain: NSCocoaErrorDomain,
            removeErrorCode: NSFileWriteNoPermissionError
        )
        XCTAssertThrowsError(try deniedStub.removeItemIfExists(at: "/any/path")) { error in
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }

        // 底层删除成功时同样不应抛错。
        let successStub = StubbedFileSystemStub(removeErrorDomain: "", removeErrorCode: 0)
        XCTAssertNoThrow(try successStub.removeItemIfExists(at: "/whatever"))
    }

    func test_removeItemIfExists_removesRealPathAndIgnoresMissingPath() throws {
        let root = try makeFileSystemTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileSystemService()

        let target = root.appendingPathComponent("to-delete", isDirectory: true)
        try service.createDirectory(at: target.path)
        try service.removeItemIfExists(at: target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // 真实文件系统下对不存在路径重复删除同样必须静默。
        XCTAssertNoThrow(try service.removeItemIfExists(
            at: root.appendingPathComponent("ghost").path
        ))
    }

    func test_directoryExists_trimsWhitespaceAndRejectsFilesAndMissingPaths() throws {
        let root = try makeFileSystemTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileSystemService()

        let directory = root.appendingPathComponent("workspace", isDirectory: true)
        try service.createDirectory(at: directory.path)
        XCTAssertTrue(service.directoryExists(at: directory.path))
        // 只去**前导**空白(粘贴杂质);尾部空白是合法目录名的一部分,不得裁掉。
        XCTAssertTrue(service.directoryExists(at: "  \(directory.path)"))

        let file = root.appendingPathComponent("note.txt")
        let wroteFile = FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        XCTAssertTrue(wroteFile)
        XCTAssertFalse(service.directoryExists(at: file.path))

        XCTAssertFalse(service.directoryExists(at: ""))
        XCTAssertFalse(service.directoryExists(at: "   \n"))
        XCTAssertFalse(service.directoryExists(at: root.appendingPathComponent("ghost").path))
    }

    /// 尾空格目录名的探测口径:必须与 LocalPathSafety.normalizedPath 一致。
    /// 此前这里做整串 trim,`"mydir "` 被探测成 `"mydir"`(不存在),磁盘刷新据此
    /// 把行判 missing 并删除记录——归一化口径不一致直接造成数据丢失。
    func test_directoryExists_detectsDirectoryWithTrailingSpaceInName() throws {
        let root = try makeFileSystemTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileSystemService()

        let spaced = root.appendingPathComponent("mydir ", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)

        XCTAssertTrue(service.directoryExists(at: spaced.path), "尾空格目录必须被识别为存在")
        XCTAssertFalse(service.directoryExists(at: root.appendingPathComponent("mydir").path))
    }
}

// MARK: - 夹具

/// 在系统临时目录下建唯一测试根(项目惯例:NSTemporaryDirectory + UUID 后缀)。
private func makeFileSystemTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ccspace-filesystem-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// 让 removeItem 按指定 Cocoa 错误码抛错的桩,用于验证 removeItemIfExists 的吞错边界。
private struct StubbedFileSystemStub: FileSystemServicing {
    let removeErrorDomain: String
    let removeErrorCode: Int

    func createDirectory(at path: String) throws {}

    func removeItem(at path: String) throws {
        if removeErrorCode != 0 {
            throw NSError(domain: removeErrorDomain, code: removeErrorCode)
        }
    }
}
