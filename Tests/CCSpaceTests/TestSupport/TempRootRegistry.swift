import Foundation

/// 测试临时根的统一登记与回收。
///
/// 此前各套件就地拼 `temporaryDirectory/UUID` 且**从不清理**:一轮测试在系统临时
/// 目录里留下上百个目录(JSONFileStore/RepositoryStore/SettingsStore 占大头),
/// 其中不少还含完整 git 仓库。
///
/// 回收时机选在**进程退出**而不是用例/套件结束:同步协调器与磁盘刷新计算器会发起
/// detached 落盘任务,用例结束不代表这些写入已停止,提前删根会复现
/// `ServiceTestSupport` 里记录过的跨用例偶发失败。
/// 同时在首次登记时清扫上一轮(创建时间早于本进程启动)的残留——崩溃或强杀时
/// atexit 不会执行,那部分靠下一轮的清扫回收。
enum TempRootRegistry {
    /// 命名空间前缀:清扫时只按它匹配,不碰系统临时目录里的其他内容。
    static let namespacePrefix = "ccspace-test-"

    private static let lock = NSLock()
    // 以下三个可变状态全部由 lock 串行化访问(Swift 6 无法自行推断,故显式标注)。
    nonisolated(unsafe) private static var roots: [URL] = []
    nonisolated(unsafe) private static var didInstallExitHandler = false
    nonisolated(unsafe) private static var sequence = 0
    /// 本进程启动时刻:早于它的目录属上一轮及更早的残留。
    private static let processStartDate = Date()

    /// 新建并登记一个测试临时根路径。返回的目录**尚未创建**,与被替换的旧写法一致
    /// (JSONFileStore 等被测代码会自己建)。
    static func makeRootURL() -> URL {
        lock.lock()
        sequence += 1
        let currentSequence = sequence
        lock.unlock()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(namespacePrefix)\(getpid())-\(currentSequence)-\(UUID().uuidString)",
                isDirectory: true
            )
        register(url)
        return url
    }

    private static func register(_ url: URL) {
        lock.lock()
        roots.append(url)
        let shouldInstall = didInstallExitHandler == false
        if shouldInstall { didInstallExitHandler = true }
        lock.unlock()
        guard shouldInstall else { return }
        sweepStaleRoots()
        atexit(testRootExitCleanup)
    }

    static func removeAllNow() {
        lock.lock()
        let pending = roots
        roots = []
        lock.unlock()
        let fileManager = FileManager.default
        for root in pending {
            try? fileManager.removeItem(at: root)
        }
    }

    /// 清掉本套件命名空间下、创建时间早于本进程启动的残留。
    private static func sweepStaleRoots() {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(namespacePrefix) {
            let createdAt = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            if createdAt < processStartDate {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

/// 便捷入口:等价于 `TempRootRegistry.makeRootURL()`。
func makeTestRootURL() -> URL {
    TempRootRegistry.makeRootURL()
}

/// 进程退出时的回收入口。`atexit` 要 C 函数指针,闭包会捕获上下文而无法转换,
/// 因此这里是文件级无捕获函数。
private func testRootExitCleanup() {
    TempRootRegistry.removeAllNow()
}
