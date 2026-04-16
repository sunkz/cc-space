import Foundation
import XCTest
@testable import CCSpace

final class WorkplaceIDEAApplicationDetectorTests: XCTestCase {
    func test_detectPrefersLaunchServicesResult() throws {
        let launchServicesURL = URL(fileURLWithPath: "/Applications/JetBrains Toolbox/IntelliJ IDEA.app")
        let detector = WorkplaceIDEAApplicationDetector(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.jetbrains.intellij" ? launchServicesURL : nil
            },
            searchRoots: [],
            candidates: WorkplaceIDEAApplicationDetector.defaultCandidates
        )

        let application = try XCTUnwrap(detector.detect())

        XCTAssertEqual(application.displayName, "IntelliJ IDEA")
        XCTAssertEqual(application.bundleIdentifier, "com.jetbrains.intellij")
        XCTAssertEqual(application.applicationURL, launchServicesURL)
    }

    func test_detectFindsApplicationInFallbackSearchRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = try createFakeApp(
            named: "IntelliJ IDEA.app",
            bundleIdentifier: "com.jetbrains.intellij",
            under: root
        )
        let detector = WorkplaceIDEAApplicationDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [root],
            candidates: WorkplaceIDEAApplicationDetector.defaultCandidates
        )

        let application = try XCTUnwrap(detector.detect())

        XCTAssertEqual(application.displayName, "IntelliJ IDEA")
        XCTAssertEqual(application.bundleIdentifier, "com.jetbrains.intellij")
        XCTAssertEqual(application.applicationURL, appURL)
    }

    func test_detectIgnoresFallbackApplicationWithUnexpectedBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try createFakeApp(
            named: "IntelliJ IDEA.app",
            bundleIdentifier: "com.example.not-idea",
            under: root
        )
        let detector = WorkplaceIDEAApplicationDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [root],
            candidates: WorkplaceIDEAApplicationDetector.defaultCandidates
        )

        XCTAssertNil(detector.detect())
    }

    func test_detectReturnsNilWhenIdeaIsUnavailable() {
        let detector = WorkplaceIDEAApplicationDetector(
            resolveApplicationURL: { _ in nil },
            searchRoots: [],
            candidates: WorkplaceIDEAApplicationDetector.defaultCandidates
        )

        XCTAssertNil(detector.detect())
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
                "CFBundleName": appName
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
