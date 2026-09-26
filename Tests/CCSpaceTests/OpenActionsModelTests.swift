import XCTest
@testable import CCSpace

@MainActor
final class OpenActionsModelTests: XCTestCase {
    func test_initRunsInitialDetection() async throws {
        let model = OpenActionsModel(
            editorDetector: detector(resolving: ["com.microsoft.VSCode"]),
            terminalDetector: detector(
                resolving: ["com.apple.Terminal", "com.googlecode.iterm2"],
                candidates: ExternalEditorDetector.terminalCandidates
            )
        )

        // 检测已移到后台线程异步发布,轮询等待结果落位(替代旧的同步断言)。
        try await waitUntilPublished(timeout: 2) {
            model.installedEditors.map(\.id) == ["vscode"]
                && model.installedTerminals.map(\.id) == ["terminal", "iterm2"]
        }
        XCTAssertEqual(model.installedEditors.map(\.id), ["vscode"])
        XCTAssertEqual(model.installedTerminals.map(\.id), ["terminal", "iterm2"])
    }

    func test_refreshPicksUpNewlyInstalledTerminal() async throws {
        let installed = MutableBundleSet(["com.apple.Terminal"])
        let terminalDetector = ExternalEditorDetector(
            resolveApplicationURL: { bundleIdentifier in
                installed.contains(bundleIdentifier)
                    ? URL(fileURLWithPath: "/fake/\(bundleIdentifier)")
                    : nil
            },
            searchRoots: [],
            candidates: ExternalEditorDetector.terminalCandidates
        )

        let model = OpenActionsModel(
            editorDetector: detector(resolving: []),
            terminalDetector: terminalDetector
        )
        try await waitUntilPublished(timeout: 2) {
            model.installedTerminals.map(\.id) == ["terminal"]
        }
        XCTAssertEqual(model.installedTerminals.map(\.id), ["terminal"])

        installed.insert("com.googlecode.iterm2")
        model.refresh()

        try await waitUntilPublished(timeout: 2) {
            model.installedTerminals.map(\.id) == ["terminal", "iterm2"]
        }
        XCTAssertEqual(model.installedTerminals.map(\.id), ["terminal", "iterm2"])
    }

    func test_allOpenActionsOrdersFinderEditorsTerminals() {
        let actions = WorkplaceSystemActions.allOpenActions(
            editors: [fakeApp(id: "vscode")],
            terminals: [fakeApp(id: "terminal")]
        )

        XCTAssertEqual(actions.map(\.id), ["finder", "vscode", "terminal"])
    }

    func test_preferredOpenActionResolvesLegacyTerminalID() {
        // 历史版本把 "terminal" 存为偏好 ID;终端独立化后仍应解析到 Terminal.app。
        let action = WorkplaceSystemActions.preferredOpenAction(
            id: "terminal",
            editors: [fakeApp(id: "vscode")],
            terminals: [fakeApp(id: "terminal")]
        )

        XCTAssertEqual(action.id, "terminal")
    }

    func test_preferredOpenActionFallsBackToFirstEditor() {
        let action = WorkplaceSystemActions.preferredOpenAction(
            id: nil,
            editors: [fakeApp(id: "vscode"), fakeApp(id: "zed")],
            terminals: [fakeApp(id: "terminal")]
        )

        XCTAssertEqual(action.id, "vscode")
    }

    func test_preferredOpenActionFallsBackToFinderWithoutEditors() {
        let action = WorkplaceSystemActions.preferredOpenAction(
            id: nil,
            editors: [],
            terminals: [fakeApp(id: "terminal")]
        )

        XCTAssertEqual(action.id, "finder")
    }

    // MARK: - Helpers

    /// 轮询等待异步发布的检测结果;超时即失败(避免慢环境下无限挂起)。
    private func waitUntilPublished(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待检测结果发布超时")
    }

    private func detector(
        resolving bundleIDs: Set<String>,
        candidates: [ExternalEditorCandidate] = ExternalEditorDetector.defaultCandidates
    ) -> ExternalEditorDetector {
        ExternalEditorDetector(
            resolveApplicationURL: { bundleIdentifier in
                bundleIDs.contains(bundleIdentifier)
                    ? URL(fileURLWithPath: "/fake/\(bundleIdentifier)")
                    : nil
            },
            searchRoots: [],
            candidates: candidates
        )
    }

    private func fakeApp(id: String) -> ExternalEditor {
        ExternalEditor(
            id: id,
            displayName: id,
            bundleIdentifier: "com.example.\(id)",
            applicationURL: URL(fileURLWithPath: "/fake/\(id).app")
        )
    }
}

/// 可变的 bundle id 集合,模拟运行期安装新应用(检测闭包不能直接捕获测试类 self)。
private final class MutableBundleSet: @unchecked Sendable {
    private var ids: Set<String>

    init(_ ids: Set<String>) {
        self.ids = ids
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func insert(_ id: String) {
        ids.insert(id)
    }
}
