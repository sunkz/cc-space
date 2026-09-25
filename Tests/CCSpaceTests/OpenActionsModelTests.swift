import XCTest
@testable import CCSpace

@MainActor
final class OpenActionsModelTests: XCTestCase {
    func test_initRunsInitialDetection() {
        let model = OpenActionsModel(
            editorDetector: detector(resolving: ["com.microsoft.VSCode"]),
            terminalDetector: detector(
                resolving: ["com.apple.Terminal", "com.googlecode.iterm2"],
                candidates: ExternalEditorDetector.terminalCandidates
            )
        )

        XCTAssertEqual(model.installedEditors.map(\.id), ["vscode"])
        XCTAssertEqual(model.installedTerminals.map(\.id), ["terminal", "iterm2"])
    }

    func test_refreshPicksUpNewlyInstalledTerminal() {
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
        XCTAssertEqual(model.installedTerminals.map(\.id), ["terminal"])

        installed.insert("com.googlecode.iterm2")
        model.refresh()

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
