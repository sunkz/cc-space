import AppKit
import Foundation

struct WorkplaceIDEAApplication: Equatable {
    let displayName: String
    let bundleIdentifier: String
    let applicationURL: URL
}

struct WorkplaceIDEAApplicationDetector {
    struct Candidate: Equatable {
        let displayName: String
        let bundleIdentifier: String
        let appBundleNames: [String]
    }

    let resolveApplicationURL: (String) -> URL?
    let fileManager: FileManager
    let searchRoots: [URL]
    let candidates: [Candidate]

    init(
        resolveApplicationURL: @escaping (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        fileManager: FileManager = .default,
        searchRoots: [URL] = Self.defaultSearchRoots(fileManager: .default),
        candidates: [Candidate] = Self.defaultCandidates
    ) {
        self.resolveApplicationURL = resolveApplicationURL
        self.fileManager = fileManager
        self.searchRoots = searchRoots
        self.candidates = candidates
    }

    func detect() -> WorkplaceIDEAApplication? {
        for candidate in candidates {
            if let applicationURL = resolveApplicationURL(candidate.bundleIdentifier) {
                return WorkplaceIDEAApplication(
                    displayName: candidate.displayName,
                    bundleIdentifier: candidate.bundleIdentifier,
                    applicationURL: applicationURL.standardizedFileURL
                )
            }
        }

        for root in searchRoots {
            for candidate in candidates {
                for appBundleName in candidate.appBundleNames {
                    let applicationURL = root.appendingPathComponent(
                        appBundleName,
                        isDirectory: true
                    )
                    guard fileManager.fileExists(atPath: applicationURL.path) else {
                        continue
                    }

                    if let bundleIdentifier = Bundle(url: applicationURL)?
                        .bundleIdentifier?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       bundleIdentifier.isEmpty == false,
                       bundleIdentifier != candidate.bundleIdentifier {
                        continue
                    }

                    return WorkplaceIDEAApplication(
                        displayName: candidate.displayName,
                        bundleIdentifier: candidate.bundleIdentifier,
                        applicationURL: applicationURL.standardizedFileURL
                    )
                }
            }
        }

        return nil
    }

    static let defaultCandidates: [Candidate] = [
        Candidate(
            displayName: "IntelliJ IDEA",
            bundleIdentifier: "com.jetbrains.intellij",
            appBundleNames: [
                "IntelliJ IDEA.app",
                "IntelliJ IDEA Ultimate.app"
            ]
        ),
        Candidate(
            displayName: "IntelliJ IDEA CE",
            bundleIdentifier: "com.jetbrains.intellij.ce",
            appBundleNames: [
                "IntelliJ IDEA CE.app",
                "IntelliJ IDEA Community Edition.app"
            ]
        )
    ]

    static func defaultSearchRoots(fileManager: FileManager) -> [URL] {
        let homeApplicationsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)

        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplicationsURL,
            URL(fileURLWithPath: "/Applications/JetBrains Toolbox", isDirectory: true),
            homeApplicationsURL.appendingPathComponent("JetBrains Toolbox", isDirectory: true)
        ]
    }
}

extension WorkplaceSystemActions {
    static let installedIDEAApplication = WorkplaceIDEAApplicationDetector().detect()

    static func openInIDEA(at path: String) throws {
        guard let application = installedIDEAApplication else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未检测到 IntelliJ IDEA"]
            )
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "目录路径不能为空"]
            )
        }

        let normalizedPath = URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "目录不存在"]
            )
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", application.applicationURL.path, normalizedPath]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "WorkplaceSystemActions",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage?.isEmpty == false
                        ? errorMessage!
                        : "无法使用 IntelliJ IDEA 打开目录"
                ]
            )
        }
    }
}
