import AppKit
import Foundation

enum OpenActionItem: Identifiable, Equatable {
    case finder
    case terminal(ExternalEditor)
    case editor(ExternalEditor)

    var id: String {
        switch self {
        case .finder: "finder"
        case .terminal(let terminal): terminal.id
        case .editor(let editor): editor.id
        }
    }

    var displayName: String {
        switch self {
        case .finder: "Finder"
        case .terminal(let terminal): terminal.displayName
        case .editor(let editor): editor.displayName
        }
    }

    /// 16pt 图标(带进程内缓存):原实现每次访问都做磁盘图标查询 + NSImage 拷贝,
    /// 叠加详情页周期刷新会在前台持续消耗 CPU;图标本质静态,查一次即可。
    @MainActor
    var icon: NSImage {
        OpenActionItemIconCache.shared.icon(for: self)
    }
}

/// OpenActionItem 图标的 MainActor 缓存,按 id 记忆化。
@MainActor
private final class OpenActionItemIconCache {
    static let shared = OpenActionItemIconCache()

    private var cache: [String: NSImage] = [:]

    func icon(for item: OpenActionItem) -> NSImage {
        if let cached = cache[item.id] {
            return cached
        }
        let original: NSImage
        switch item {
        case .finder:
            original = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .terminal(let terminal):
            original = terminal.appIcon
        case .editor(let editor):
            original = editor.appIcon
        }
        let icon = (original.copy() as? NSImage) ?? original
        icon.size = NSSize(width: 16, height: 16)
        cache[item.id] = icon
        return icon
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

/// @unchecked Sendable:fileManager 与 searchRoots/candidates 初始化后不变,
/// FileManager.default 官方文档明确可多线程调用;resolveApplicationURL 标注 @Sendable。
struct ExternalEditorDetector: @unchecked Sendable {
    let resolveApplicationURL: @Sendable (String) -> URL?
    let fileManager: FileManager
    let searchRoots: [URL]
    let candidates: [ExternalEditorCandidate]

    init(
        resolveApplicationURL: @escaping @Sendable (String) -> URL? = {
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

    /// 终端应用候选:与编辑器分开检测、分开呈现(Terminal 为 macOS 必装,id 固定
    /// "terminal",历史保存的偏好 ID 继续有效)。
    static let terminalCandidates: [ExternalEditorCandidate] = [
        ExternalEditorCandidate(
            id: "terminal",
            displayName: "终端",
            bundleIdentifier: "com.apple.Terminal",
            appBundleNames: [
                "Terminal.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "iterm2",
            displayName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            appBundleNames: [
                "iTerm.app",
            ]
        ),
        ExternalEditorCandidate(
            id: "warp",
            displayName: "Warp",
            bundleIdentifier: "dev.warp.Warp-Stable",
            appBundleNames: [
                "Warp.app",
            ]
        ),
    ]

    /// Terminal.app 位于 /System 而非搜索根目录,检测不到时兜底补上,保证"终端"入口始终存在。
    static func withTerminalFallback(_ detected: [ExternalEditor]) -> [ExternalEditor] {
        guard detected.contains(where: { $0.id == "terminal" }) == false else {
            return detected
        }
        let fallback = ExternalEditor(
            id: "terminal",
            displayName: "终端",
            bundleIdentifier: "com.apple.Terminal",
            applicationURL: URL(
                fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
                isDirectory: true
            )
        )
        return [fallback] + detected
    }

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
    static func allOpenActions(
        editors: [ExternalEditor],
        terminals: [ExternalEditor]
    ) -> [OpenActionItem] {
        [.finder] + editors.map { .editor($0) } + terminals.map { .terminal($0) }
    }

    static func preferredOpenAction(
        id: String?,
        editors: [ExternalEditor],
        terminals: [ExternalEditor]
    ) -> OpenActionItem {
        let actions = allOpenActions(editors: editors, terminals: terminals)
        if let id, let action = actions.first(where: { $0.id == id }) {
            return action
        }
        if let firstEditor = editors.first {
            return .editor(firstEditor)
        }
        return .finder
    }

    static func performOpenAction(_ action: OpenActionItem, at path: String) throws {
        switch action {
        case .finder:
            showInFinder(at: path)
        case .terminal(let terminal):
            try openTerminal(terminal, at: path)
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", editor.applicationURL.path, normalizedPath]
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// 打开方式(Finder/编辑器/终端)的检测结果模型:启动即检测,之后由宿主定时刷新,
/// 运行期新安装的编辑器/终端无需重启 App 即可出现在"打开方式"菜单里。
/// 菜单渲染始终同步读当前值,检测不在菜单打开时触发,不影响交互。
@MainActor
final class OpenActionsModel: ObservableObject {
    @Published private(set) var installedEditors: [ExternalEditor] = []
    @Published private(set) var installedTerminals: [ExternalEditor] = []

    private let editorDetector: ExternalEditorDetector
    private let terminalDetector: ExternalEditorDetector

    init(
        editorDetector: ExternalEditorDetector = ExternalEditorDetector(),
        terminalDetector: ExternalEditorDetector = ExternalEditorDetector(
            candidates: ExternalEditorDetector.terminalCandidates
        )
    ) {
        self.editorDetector = editorDetector
        self.terminalDetector = terminalDetector
        refresh()
    }

    /// 代际号:定时刷新(120s 一次)下先后两次 refresh 的后台检测可能乱序完成,
    /// 旧结果晚到会覆盖新结果,回主线程落笔前比对代际,只认最新一次。
    private var refreshGeneration = 0

    /// 检测移到后台线程:扫描 /Applications 与读取 Bundle Info.plist 都是磁盘 IO,
    /// 在 MainActor 上周期执行会造成周期性卡顿。扫描结果回主线程发布;
    /// 两次 detectAll 仍按 editors → terminals 顺序成对提交,发布语义与同步版一致。
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let editorDetector = editorDetector
        let terminalDetector = terminalDetector
        Task.detached(priority: .utility) {
            let editors = editorDetector.detectAll()
            let terminals = ExternalEditorDetector.withTerminalFallback(
                terminalDetector.detectAll()
            )
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.installedEditors = editors
                self.installedTerminals = terminals
            }
        }
    }
}
