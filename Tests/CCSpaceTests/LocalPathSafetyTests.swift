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

    /// 相对路径必须归一为空串(由调用点的 isEmpty 防御统一转拒绝)。
    /// 相对路径的锚点是本进程 CWD——对 GUI app 是未定义值且会随环境漂移,
    /// 同一配置两次启动归一成不同路径,锁 key 与 containment 判定随之失效。
    func test_normalizedPathRejectsRelativePaths() {
        XCTAssertEqual(LocalPathSafety.normalizedPath("workplaces/demo"), "")
        XCTAssertEqual(LocalPathSafety.normalizedPath("./demo"), "")
        XCTAssertEqual(LocalPathSafety.normalizedPath("~/demo"), "")
        // 前导空白 + 相对路径同样拒绝(不能因为 trim 后看似绝对就放过)。
        XCTAssertEqual(LocalPathSafety.normalizedPath("  demo"), "")
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

    // MARK: - 悬空符号链接(第七轮评审 P2)

    /// 链接在、目标不在:`resolvingSymlinksInPath` 解析不了它(实测原样返回),
    /// 会被当成"不存在的尾部"词法拼回并按"根内"放行;目标一旦被外部进程落地,
    /// 克隆/删除就物理落在根外。必须 fail-closed。
    func test_isWithinDirectoryRejectsDanglingSymlinkComponent() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LocalPathSafety-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("ws", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let dangling = workspaceRoot.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createSymbolicLink(
            at: dangling,
            withDestinationURL: tempRoot.appendingPathComponent("not-yet-created", isDirectory: true)
        )

        XCTAssertTrue(LocalPathSafety.hasDanglingSymlink(in: dangling.path))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory(dangling.path, rootPath: workspaceRoot.path))
        XCTAssertFalse(LocalPathSafety.isWithinDirectory(
            dangling.path + "/inner/file.txt",
            rootPath: workspaceRoot.path
        ))
        XCTAssertThrowsError(try LocalPathSafety.validateManagedPath(dangling.path, within: workspaceRoot.path))
    }

    /// 链接指向**已存在**的根内目录:不算悬空,containment 照旧放行(不误伤正常用法)。
    func test_isWithinDirectoryAcceptsSymlinkPointingInsideRoot() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LocalPathSafety-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("ws", isDirectory: true)
        let inside = workspaceRoot.appendingPathComponent("real", isDirectory: true)
        try fileManager.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let link = workspaceRoot.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: inside)

        XCTAssertFalse(LocalPathSafety.hasDanglingSymlink(in: link.path))
        XCTAssertTrue(LocalPathSafety.isWithinDirectory(link.path, rootPath: workspaceRoot.path))
    }

    // MARK: - 严格包含(破坏性操作专用判定)

    /// 破坏性操作(递归删除、整树移动)必须用 `isStrictlyWithinDirectory`:
    /// `isWithinDirectory` 把"同一目录"也判为受管(创建子路径时才是想要的语义),
    /// 而记录路径一旦被手工编辑/损坏成恰好等于受管根,`rm -rf <root>` 会把整棵
    /// 受管根(含其它工作区)一并删掉。
    func test_isStrictlyWithinDirectoryRejectsTheRootItself() {
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/tmp/root", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/tmp/root/", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/tmp/root/./", rootPath: "/tmp/root"))
    }

    /// 大小写归一后等于根的输入同样必须拒绝:macOS 默认卷大小写不敏感,
    /// 放宽分支会把它放行,而它指向的正是受管根本身。
    func test_isStrictlyWithinDirectoryRejectsRootDifferingOnlyByCase() {
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/TMP/ROOT", rootPath: "/tmp/root"))
    }

    func test_isStrictlyWithinDirectoryAcceptsRealDescendants() {
        XCTAssertTrue(LocalPathSafety.isStrictlyWithinDirectory("/tmp/root/ios-dev", rootPath: "/tmp/root"))
        XCTAssertTrue(LocalPathSafety.isStrictlyWithinDirectory("/tmp/root/ios-dev/api", rootPath: "/tmp/root"))
        // 尚未落盘的目标(新建克隆场景)同样要判是,否则创建流程第一步就被拒。
        XCTAssertTrue(
            LocalPathSafety.isStrictlyWithinDirectory(
                "/tmp/root/ios-dev/not-created-yet",
                rootPath: "/tmp/root"
            )
        )
    }

    func test_isStrictlyWithinDirectoryStillRejectsOutsiders() {
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/tmp/rootx", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("/tmp", rootPath: "/tmp/root"))
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory("", rootPath: "/tmp/root"))
    }

    /// 符号链接别名指向根自身:词法上像子路径,解析后与根同一目录——
    /// 这正是"删根"最隐蔽的形态,必须判否。
    func test_isStrictlyWithinDirectoryRejectsSymlinkAliasResolvingToRoot() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("LocalPathSafety-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("ws", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let alias = workspaceRoot.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: workspaceRoot)

        // 普通 containment 判"是"(等价于根),严格 containment 必须判"否"。
        XCTAssertTrue(LocalPathSafety.isWithinDirectory(alias.path, rootPath: workspaceRoot.path))
        XCTAssertFalse(LocalPathSafety.isStrictlyWithinDirectory(alias.path, rootPath: workspaceRoot.path))
        // 别名下的真实子目录仍是根内后代,不得被误伤。
        try fileManager.createDirectory(
            at: workspaceRoot.appendingPathComponent("real", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            LocalPathSafety.isStrictlyWithinDirectory(
                alias.path + "/real",
                rootPath: workspaceRoot.path
            )
        )
    }

    func test_validateStrictlyContainedPathThrowsForRootItself() {
        XCTAssertNoThrow(
            try LocalPathSafety.validateStrictlyContainedPath("/tmp/root/ios-dev", within: "/tmp/root")
        )
        XCTAssertThrowsError(
            try LocalPathSafety.validateStrictlyContainedPath("/tmp/root", within: "/tmp/root")
        )
        XCTAssertThrowsError(
            try LocalPathSafety.validateStrictlyContainedPath("/tmp/elsewhere", within: "/tmp/root")
        )
    }
}
