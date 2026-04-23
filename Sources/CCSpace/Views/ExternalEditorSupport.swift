import AppKit
import Foundation

enum OpenActionItem: Identifiable, Equatable {
    case finder
    case terminal
    case editor(ExternalEditor)

    var id: String {
        switch self {
        case .finder: "finder"
        case .terminal: "terminal"
        case .editor(let editor): editor.id
        }
    }

    var displayName: String {
        switch self {
        case .finder: "Finder"
        case .terminal: "终端"
        case .editor(let editor): editor.displayName
        }
    }

    var icon: NSImage {
        let image: NSImage
        switch self {
        case .finder:
            image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .terminal:
            image = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        case .editor(let editor):
            image = editor.appIcon
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

struct ExternalEditor: Equatable, Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let applicationURL: URL

    var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

struct ExternalEditorCandidate: Equatable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let appBundleNames: [String]
}

struct ExternalEditorDetector {
    let resolveApplicationURL: (String) -> URL?
    let fileManager: FileManager
    let searchRoots: [URL]
    let candidates: [ExternalEditorCandidate]

    init(
        resolveApplicationURL: @escaping (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        fileManager: FileManager = .default,
        searchRoots: [URL] = defaultSearchRoots(fileManager: .default),
        candidates: [ExternalEditorCandidate] = defaultCandidates
    ) {
        self.resolveApplicationURL = resolveApplicationURL
        self.fileManager = fileManager
        self.searchRoots = searchRoots
        self.candidates = candidates
    }

    func detectAll() -> [ExternalEditor] {
        var found: [ExternalEditor] = []
        var seenIDs: Set<String> = []

        for candidate in candidates {
            guard seenIDs.contains(candidate.id) == false else { continue }

            if let applicationURL = resolveApplicationURL(candidate.bundleIdentifier) {
                found.append(ExternalEditor(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    bundleIdentifier: candidate.bundleIdentifier,
                    applicationURL: applicationURL.standardizedFileURL
                ))
                seenIDs.insert(candidate.id)
                continue
            }

            for root in searchRoots {
                var matched = false
                for appBundleName in candidate.appBundleNames {
                    let applicationURL = root.appendingPathComponent(appBundleName, isDirectory: true)
                    guard fileManager.fileExists(atPath: applicationURL.path) else { continue }

                    if let bundleIdentifier = Bundle(url: applicationURL)?
                        .bundleIdentifier?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       bundleIdentifier.isEmpty == false,
                       bundleIdentifier != candidate.bundleIdentifier {
                        continue
                    }

                    found.append(ExternalEditor(
                        id: candidate.id,
                        displayName: candidate.displayName,
                        bundleIdentifier: candidate.bundleIdentifier,
                        applicationURL: applicationURL.standardizedFileURL
                    ))
                    seenIDs.insert(candidate.id)
                    matched = true
                    break
                }
                if matched { break }
            }
        }

        return found
    }

    static let defaultCandidates: [ExternalEditorCandidate] = [
        ExternalEditorCandidate(
            id: "vscode",
            displayName: "VS Code",
            bundleIdentifier: "com.microsoft.VSCode",
            appBundleNames: [
                "Visual Studio Code.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "cursor",
            displayName: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            appBundleNames: [
                "Cursor.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "zed",
            displayName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            appBundleNames: [
                "Zed.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "idea",
            displayName: "IntelliJ IDEA",
            bundleIdentifier: "com.jetbrains.intellij",
            appBundleNames: [
                "IntelliJ IDEA.app",
                "IntelliJ IDEA Ultimate.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "idea-ce",
            displayName: "IntelliJ IDEA CE",
            bundleIdentifier: "com.jetbrains.intellij.ce",
            appBundleNames: [
                "IntelliJ IDEA CE.app",
                "IntelliJ IDEA Community Edition.app",
            ]
        ),
    ]

    static func defaultSearchRoots(fileManager: FileManager) -> [URL] {
        let homeApplicationsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)

        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplicationsURL,
            URL(fileURLWithPath: "/Applications/JetBrains Toolbox", isDirectory: true),
            homeApplicationsURL.appendingPathComponent("JetBrains Toolbox", isDirectory: true),
        ]
    }
}

extension WorkplaceSystemActions {
    static let installedEditors: [ExternalEditor] = ExternalEditorDetector().detectAll()

    static var allOpenActions: [OpenActionItem] {
        [.finder] + installedEditors.map { .editor($0) } + [.terminal]
    }

    static func preferredOpenAction(id: String?) -> OpenActionItem {
        if let id, let action = allOpenActions.first(where: { $0.id == id }) {
            return action
        }
        if let firstEditor = installedEditors.first {
            return .editor(firstEditor)
        }
        return .finder
    }

    static func performOpenAction(_ action: OpenActionItem, at path: String) throws {
        switch action {
        case .finder:
            showInFinder(at: path)
        case .terminal:
            try openTerminal(at: path)
        case .editor(let editor):
            try openInEditor(editor, at: path)
        }
    }

    static func openInEditor(_ editor: ExternalEditor, at path: String) throws {
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
        process.arguments = ["-a", editor.applicationURL.path, normalizedPath]
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
                        : "无法使用 \(editor.displayName) 打开目录",
                ]
            )
        }
    }
}
