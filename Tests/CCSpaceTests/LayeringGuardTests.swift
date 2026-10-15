import XCTest
@testable import CCSpace

/// 分层依赖的静态守护锁。
///
/// AGENTS.md 把依赖方向写死为 `Views → AppState/Stores → Services → Models`,
/// 并明确"View 不直接调 git,必须经 Store/Coordinator"。这条约定纯靠人守,
/// 每轮评审都会重新发现几处 View 直接调 git(第 14 轮一次性清了 7 处:
/// 分支快照编排、diff 三来源、提交详情、全文 blob、最近提交主题、remoteURL)。
/// 本测试把它变成可执行约束:再写出一处就直接编译期之后的测试红。
final class LayeringGuardTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CCSpaceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private func swiftFiles(in directory: String) throws -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "找不到源码目录,守护测试本身已失效:\(root.path)"
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// 真实代码行(带原文件行号):约定违例只看代码,文档注释里提到
    /// `gitService.remoteURL` 不算,行号必须是文件里的原始行号,否则定位不到。
    private func codeLines(of source: String) -> [(line: Int, text: String)] {
        source.split(separator: "\n").enumerated().compactMap { index, rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") == false, trimmed.hasPrefix("*") == false else {
                return nil
            }
            return (index + 1, line)
        }
    }

    /// Views 层不得直接调用 GitServicing 的成员。
    ///
    /// 允许:把 `gitService` 作为初始化参数注入给 Service(组合根该做的事);
    /// 禁止:`gitService.xxx(...)` 这种在视图代码里直接驱动 git 进程。
    func test_viewsDoNotCallGitServiceMembersDirectly() throws {
        let pattern = "gitService."
        var violations: [String] = []

        for url in try swiftFiles(in: "Sources/CCSpace/Views") {
            let source = try String(contentsOf: url, encoding: .utf8)
            for entry in codeLines(of: source) where entry.text.contains(pattern) {
                violations.append(
                    "\(url.lastPathComponent):\(entry.line) \(entry.text.trimmingCharacters(in: .whitespaces))"
                )
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Views 层直接调 git(应经 Store/Coordinator/Service):\n" + violations.joined(separator: "\n")
        )
    }

    /// Services 层不得反向依赖 Views 的类型(层倒置)。
    func test_servicesDoNotDependOnViewPayloadTypes() throws {
        let forbidden = ["DiffWindowPayload", "BranchCompareWindowPayload", "CommitLogWindowPayload"]
        var violations: [String] = []

        for url in try swiftFiles(in: "Sources/CCSpace/Services") {
            let source = try String(contentsOf: url, encoding: .utf8)
            for entry in codeLines(of: source) {
                if let hit = forbidden.first(where: { entry.text.contains($0) }) {
                    violations.append(
                        "\(url.lastPathComponent):\(entry.line) 引用了 Views 类型 \(hit)"
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Services 反向依赖 Views 类型,来源映射应留在 View 侧:\n" + violations.joined(separator: "\n")
        )
    }
}
