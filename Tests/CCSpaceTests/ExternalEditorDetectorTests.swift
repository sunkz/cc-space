import Foundation
import XCTest
@testable import CCSpace

final class ExternalEditorDetectorTests: XCTestCase {
    func test_detectPrefersLaunchServicesResult() throws {
        let launchServicesURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let detector = ExternalEditorDetector(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode" ? launchServicesURL : nil
            },
            searchRoots: [],
            candidates: ExternalEditorDetector.defaultCandidates
        )

        let editors = detector.detectAll()
        let vscode = try XCTUnwrap(editors.first { $0.id == "vscode" })

        XCTAssertEqual(vscode.displayName, "VS Code")
        XCTAssertEqual(vscode.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(vscode.applicationURL, launchServicesURL)
    }

    func test_detectFindsApplicationInFallbackSearchRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = try createFakeApp(
            named: "IntelliJ IDEA.app",
            bundleIdentifier: "com.jetbrains.intellij",
            under: root
        )
        let detector = ExternalEditorDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [root],
            candidates: ExternalEditorDetector.defaultCandidates
        )

        let editors = detector.detectAll()
        let idea = try XCTUnwrap(editors.first { $0.id == "idea" })

        XCTAssertEqual(idea.displayName, "IntelliJ IDEA")
        XCTAssertEqual(idea.bundleIdentifier, "com.jetbrains.intellij")
        XCTAssertEqual(idea.applicationURL, appURL)
    }

    func test_detectIgnoresFallbackApplicationWithUnexpectedBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try createFakeApp(
            named: "IntelliJ IDEA.app",
            bundleIdentifier: "com.example.not-idea",
            under: root
        )
        let detector = ExternalEditorDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [root],
            candidates: ExternalEditorDetector.defaultCandidates
        )

        let editors = detector.detectAll()
        XCTAssertNil(editors.first { $0.id == "idea" })
    }

    func test_detectReturnsEmptyWhenNoEditorIsAvailable() {
        let detector = ExternalEditorDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [],
            candidates: ExternalEditorDetector.defaultCandidates
        )

        XCTAssertTrue(detector.detectAll().isEmpty)
    }

    func test_detectFindsMultipleEditors() throws {
        let vscodeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let ideaURL = URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app")
        let detector = ExternalEditorDetector(
            resolveApplicationURL: { bundleIdentifier in
                switch bundleIdentifier {
                case "com.microsoft.VSCode": return vscodeURL
                case "com.jetbrains.intellij": return ideaURL
                default: return nil
                }
            },
            searchRoots: [],
            candidates: ExternalEditorDetector.defaultCandidates
        )

        let editors = detector.detectAll()
        XCTAssertTrue(editors.contains { $0.id == "vscode" })
        XCTAssertTrue(editors.contains { $0.id == "idea" })
    }

    @discardableResult
    private func createFakeApp(
        named appName: String,
        bundleIdentifier: String,
        under root: URL
    ) throws -> URL {
        let appURL = root.appendingPathComponent(appName, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": appName,
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )

        return appURL
    }
}
