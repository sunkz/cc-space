import XCTest
@testable import CCSpace

/// `LocalPathSafety` 是克隆落盘 / 工作区删除 / 仓库删除 / 改名的唯一一道路径越权防线,
/// 回归会直接导致数据丢失,这里的用例按"拒绝分支逐条覆盖"来写。
final class LocalPathSafetyTests: XCTestCase {

    // MARK: - validateComponent

    func test_validateComponentAcceptsOrdinaryName() throws {
        XCTAssertEqual(try LocalPathSafety.validateComponent("ios-dev", fieldName: "名称"), "ios-dev")
    }

    func test_validateComponentTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try LocalPathSafety.validateComponent("  ios-dev  ", fieldName: "名称"), "ios-dev")
    }

    func test_validateComponentRejectsEmptyAndWhitespaceOnly() {
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("", fieldName: "名称")) { error in
            XCTAssertEqual(error as? LocalPathSafetyError, .invalidComponent(fieldName: "名称"))
        }
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("   ", fieldName: "名称"))
    }

    func test_validateComponentRejectsDotAndDotDot() {
        XCTAssertThrowsError(try LocalPathSafety.validateComponent(".", fieldName: "名称"))
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("..", fieldName: "名称"))
    }

    func test_validateComponentRejectsPathSeparator() {
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("a/b", fieldName: "名称"))
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("/etc", fieldName: "名称"))
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("ios-dev/", fieldName: "名称"))
    }

    func test_validateComponentRejectsColonAndNullByte() {
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("a:b", fieldName: "名称"))
        XCTAssertThrowsError(try LocalPathSafety.validateComponent("a\0b", fieldName: "名称"))
    }

    /// 这些是合法文件名,误拒会让用户建不了一个正常的工作区。
    func test_validateComponentAcceptsNamesThatMerelyLookSuspicious() throws {
        XCTAssertEqual(try LocalPathSafety.validateComponent("file..txt", fieldName: "名称"), "file..txt")
        XCTAssertEqual(try LocalPathSafety.validateComponent("a.b.c", fieldName: "名称"), "a.b.c")
        XCTAssertEqual(try LocalPathSafety.validateComponent("my project (2)", fieldName: "名称"), "my project (2)")
    }

    // MARK: - normalizedPath

    func test_normalizedPathTrimsLeadingOnlyAndStandardizes() {
        // 前导空白是粘贴杂质,去掉;尾随空格可能是真实目录名的一部分,必须原样保留。
        XCTAssertEqual(LocalPathSafety.normalizedPath("  /tmp/demo  "), "/tmp/demo  ")
        XCTAssertEqual(LocalPathSafety.normalizedPath("/tmp/demo/../demo"), "/tmp/demo")
        XCTAssertEqual(LocalPathSafety.normalizedPath("/tmp//demo/"), "/tmp/demo")
    }

    func test_normalizedPathKeepsTrailingWhitespaceOfRealPath() {
        XCTAssertEqual(LocalPathSafety.normalizedPath("/tmp/dir "), "/tmp/dir ")
        XCTAssertEqual(LocalPathSafety.normalizedPath("/tmp/dir\n"), "/tmp/dir\n")
    }

    func test_normalizedPathReturnsEmptyForBlankInput() {
        XCTAssertEqual(LocalPathSafety.normalizedPath(""), "")
        XCTAssertEqual(LocalPathSafety.normalizedPath("   "), "")
    }

    // MARK: - childPath

    func test_childPathJoinsComponentUnderParent() throws {
        XCTAssertEqual(
            try LocalPathSafety.childPath(in: "/tmp/root", component: "ios-dev", fieldName: "工作区名称"),
            "/tmp/root/ios-dev"
        )
    }

    func test_childPathRejectsTraversalComponent() {
        XCTAssertThrowsError(
            try LocalPathSafety.childPath(in: "/tmp/root", component: "..", fieldName: "工作区名称")
        ) { error in
            XCTAssertEqual(error as? LocalPathSafetyError, .invalidComponent(fieldName: "工作区名称"))
        }
    }

    func test_childPathRejectsEmptyParent() {
        XCTAssertThrowsError(
            try LocalPathSafety.childPath(in: "   ", component: "ios-dev", fieldName: "工作区名称")
        ) { error in
            XCTAssertEqual(error as? LocalPathSafetyError, .unsafeManagedPath)
        }
    }

    /// 目录名尾部空格是合法文件名:childPath 不得把它 trim 掉后再做越界校验,
    /// 否则合法的受管路径会被误判 unsafeManagedPath。
    func test_childPathPreservesTrailingWhitespaceOfParentName() throws {
        XCTAssertEqual(
            try LocalPathSafety.childPath(in: "/tmp/root ", component: "ios-dev", fieldName: "工作区名称"),
            "/tmp/root /ios-dev"
        )
    }

    // MARK: - isWithinDirectory

    func test_isWithinDirectoryAcceptsDirectChild() {
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/root/ios-dev", rootPath: "/tmp/root"))
    }

    func test_isWithinDirectoryAcceptsNestedDescendant() {
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/root/ios-dev/api", rootPath: "/tmp/root"))
    }

    func test_isWithinDirectoryAcceptsRootItself() {
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/root", rootPath: "/tmp/root"))
    }

    /// 前缀相同但不是子目录(如 /tmp/root 与 /tmp/rootx)必须判否,
    /// 否则纯字符串 hasPrefix 会把兄弟目录当成受管目录放行。
    func test_isWithinDirectoryRejectsSiblingDirectoryWithSharedPrefix() {
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/tmp/rootx", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/tmp/root-2/ios-dev", rootPath: "/tmp/root"))
    }

    func test_isWithinDirectoryRejectsParentAndUnrelatedPath() {
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/tmp", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/etc/passwd", rootPath: "/tmp/root"))
    }

    func test_isWithinDirectoryRejectsEmptyInput() {
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/tmp/root/ios-dev", rootPath: ""))
    }

    /// macOS 默认卷大小写不敏感:仅大小写不同的路径指向同一目录,
    /// 严格区分大小写会把合法受管路径误判为越界。
    func test_isWithinDirectoryComparesCaseInsensitively() {
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/TMP/root/ios-dev", rootPath: "/tmp/root"))
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/root/Ios-Dev", rootPath: "/tmp/ROOT"))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory("/tmp/rootx", rootPath: "/tmp/ROOT"))
    }

    /// 目录名含尾随空格时,受管子路径与根路径应正常匹配(不被 trim 改写后误判)。
    func test_isWithinDirectoryAcceptsTrailingSpaceDirectoryNames() {
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/ws /repo", rootPath: "/tmp/ws "))
        XCTAssertTrue(LocalPathSafety.isWithinDirectory("/tmp/ws /repo ", rootPath: "/tmp/ws "))
    }

    /// 纵深防御:工作区根内的中间符号链接目录指向根外时,
    /// 纯词法前缀比较会放行,必须解析符号链接后判为越界。
    func test_isWithinDirectoryRejectsEscapeThroughSymlinkedAncestor() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LocalPathSafety-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("ws", isDirectory: true)
        let outside = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try? "secret".write(
            to: outside.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        // ws/repo 是指向 ws/../outside 的符号链接目录。
        try fileManager.createSymbolicLink(
            at: workspaceRoot.appendingPathComponent("repo", isDirectory: true),
            withDestinationURL: outside
        )
        defer { try? fileManager.removeItem(at: tempRoot) }

        let linkPath = workspaceRoot.appendingPathComponent("repo", isDirectory: true).path
        // 词法上完全在根内,物理上在根外:必须判否。
        XCTAssertFalse(LocalPathSafety.isWithinDirectory(
            linkPath + "/secret.txt",
            rootPath: workspaceRoot.path
        ))
        // 目标文件尚不存在(新建克隆场景):尾部不存在也要回溯解析祖先符号链接。
        XCTAssertFalse(LocalPathSafety.isWithinDirectory(
            linkPath + "/not-created-yet.txt",
            rootPath: workspaceRoot.path
        ))
        // 非符号链接的正常子目录仍然判是。
        XCTAssertTrue(LocalPathSafety.isWithinDirectory(
            workspaceRoot.path + "/real-dir/file.txt",
            rootPath: workspaceRoot.path
        ))
    }

    // MARK: - validateManagedPath

    func test_validateManagedPathPassesForChildAndThrowsForOutsider() {
        XCTAssertNoThrow(try LocalPathSafety.validateManagedPath("/tmp/root/ios-dev", within: "/tmp/root"))
        XCTAssertThrowsError(try LocalPathSafety.validateManagedPath("/tmp/elsewhere", within: "/tmp/root"))
    }
}
