import XCTest
@testable import CCSpace

/// 所有 `makeServiceStores()` 共用的临时根。
///
/// 此前每次调用各建一个随机目录且**从不清理**:该函数被调用约 40 次,一轮测试
/// 会在系统临时目录里留下几十个永不删除的目录(里面还含完整 git 仓库)。
/// 改成共享固定根统一治理;但固定根下**每次调用仍分独立 UUID 子目录**——
/// 此前"每次调用先清空整个根"会把更早测试遗留的后台 detached 写入(同步协调器/
/// 刷新计算器的迟到落盘)连带删掉,产生跨用例的偶发失败。
/// 现在只在进程内首次调用时清一次陈旧残留,各用例互不删文件;
/// 残留判定额外按 `pid-<n>` 目录名排除仍存活的进程根,使同机并发的两个测试进程互不侵犯。
private let serviceTestBaseRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccspace-service-tests", isDirectory: true)

/// 本进程的测试根:按 pid 分目录,使并发运行的两个测试进程(同机双跑、CI 矩阵)
/// 天然互不重叠——对方按日期做的陈旧清理不再可能删掉本进程正在使用的根。
private let serviceTestProcessRoot = serviceTestBaseRoot
    .appendingPathComponent("pid-\(getpid())", isDirectory: true)

/// 进程启动时刻,作为陈旧残留清理的判定基准。
/// 此前用固定"-1 小时"阈值:连续两轮测试间隔不足 1 小时时,上一轮的残留永远清不掉。
/// 以进程启动时间为 cutoff,任何创建时间早于本进程启动的目录都属上一轮(或更早)的残留;
/// 本进程正在使用的根创建时间必然不早于进程启动,绝不会被误删——
/// 这保住了"不删当前运行根"的约定(避免连带删掉 detached 迟到写入的目标)。
private let serviceTestProcessStartDate = Date()

/// Swift 6 严格并发下可变全局会被诊断为数据竞争,用锁包裹的盒子承载"一次性清理"标记。
private final class ServiceTestCleanupFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

private let serviceTestCleanupFlag = ServiceTestCleanupFlag()

@MainActor
func makeServiceStores() throws -> (
    repositoryStore: RepositoryStore,
    workplaceStore: WorkplaceStore,
    workspaceRoot: URL
) {
    let fileManager = FileManager.default
    let caseRoot = serviceTestProcessRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    if serviceTestCleanupFlag.setIfFirst() {
        // 清的是**其它进程**留下的陈旧目录:创建时间早于本进程启动,且对应 pid 已不在。
        // pid 存活判定挡住同机并发场景——仅按日期判断会删掉另一个正在跑的测试进程的文件。
        // 无法解析 pid 的目录(旧版本遗留的裸 UUID 根)退回纯日期判定。
        let cutoff = serviceTestProcessStartDate
        if let entries = try? fileManager.contentsOfDirectory(
            at: serviceTestBaseRoot,
            includingPropertiesForKeys: [.creationDateKey]
        ) {
            for entry in entries {
                let createdAt = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? .distantPast
                guard createdAt < cutoff else { continue }
                if let ownerPid = serviceTestProcessID(ofRootNamed: entry.lastPathComponent),
                   kill(ownerPid, 0) == 0 {
                    continue
                }
                try? fileManager.removeItem(at: entry)
            }
        }
    }
    let appSupportRoot = caseRoot.appendingPathComponent("app-support", isDirectory: true)
    let workspaceRoot = caseRoot.appendingPathComponent("workspace", isDirectory: true)
    try fileManager.createDirectory(
        at: workspaceRoot,
        withIntermediateDirectories: true,
        attributes: nil
    )

    let fileStore = JSONFileStore(rootDirectory: appSupportRoot)
    return (
        repositoryStore: RepositoryStore(fileStore: fileStore),
        workplaceStore: WorkplaceStore(fileStore: fileStore),
        workspaceRoot: workspaceRoot
    )
}

/// 从 `pid-<n>` 形态的测试根目录名解析归属进程;非该形态返回 nil。
private func serviceTestProcessID(ofRootNamed name: String) -> Int32? {
    guard name.hasPrefix("pid-") else { return nil }
    return Int32(name.dropFirst(4))
}

/// 断言异步表达式抛出了**指定类型**的错误。
///
/// 早期版本在 catch 里只写 `XCTAssertTrue(true)`,等于"抛出任何错误都算通过"——
/// 像"路径越权的删除必须被拒绝"这类安全断言因此形同虚设。这里强制校验错误类型。
/// 用 `Any.Type` 而不是泛型参数:测试里的 stub 错误多是 fileprivate 类型,
/// 作泛型实参会受到可见性限制,而 `Any.Type` 只需调用点能看到类型名。
@MainActor
func XCTAssertThrowsErrorAsync(
    _ expectedType: Any.Type,
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("期望抛出 \(expectedType) 类型的错误，但表达式正常返回", file: file, line: line)
    } catch {
        let actualType = type(of: error)
        guard actualType == expectedType else {
            XCTFail(
                "期望错误类型 \(expectedType)，实际是 \(actualType)：\(error)",
                file: file,
                line: line
            )
            return
        }
    }
}
