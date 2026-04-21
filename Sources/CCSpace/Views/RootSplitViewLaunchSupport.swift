import CoreGraphics
import Foundation

enum CCSpaceScreenshotScene: String, Equatable {
    case settingsOverview = "settings-overview"
    case workplaceDetail = "workplace-detail"
    case createWorkplace = "create-workplace"
}

struct WorkplaceCreateSeed: Equatable {
    let name: String
    let branch: String
    let selectedRepositoryIDs: Set<UUID>

    static let empty = WorkplaceCreateSeed(
        name: "",
        branch: "",
        selectedRepositoryIDs: []
    )
}

struct CCSpaceLaunchConfiguration {
    static let defaultWindowSize = CGSize(width: 860, height: 580)
    static let screenshotWindowSize = CGSize(width: 960, height: 640)

    let appSupportDirectory: URL?
    let screenshotScene: CCSpaceScreenshotScene?
    let screenshotWorkplaceName: String?
    let createWorkplaceName: String?
    let createWorkplaceBranch: String?
    let createSelectedRepositoryNames: [String]
    let windowSize: CGSize

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let scene = Self.screenshotScene(from: environment)

        appSupportDirectory = Self.appSupportDirectory(from: environment)
        screenshotScene = scene
        screenshotWorkplaceName = Self.trimmedValue(
            environment["CCSPACE_SCREENSHOT_WORKPLACE_NAME"]
        )
        createWorkplaceName = Self.trimmedValue(
            environment["CCSPACE_SCREENSHOT_CREATE_NAME"]
        )
        createWorkplaceBranch = Self.trimmedValue(
            environment["CCSPACE_SCREENSHOT_CREATE_BRANCH"]
        )
        createSelectedRepositoryNames = Self.csvValues(
            environment["CCSPACE_SCREENSHOT_CREATE_SELECTED_REPOSITORIES"]
        )
        windowSize =
            Self.windowSize(from: environment)
            ?? (scene != nil ? Self.screenshotWindowSize : Self.defaultWindowSize)
    }

    func targetWorkplace(in workplaces: [Workplace]) -> Workplace? {
        if let screenshotWorkplaceName {
            return workplaces.first { $0.name == screenshotWorkplaceName } ?? workplaces.first
        }
        return workplaces.first
    }

    func createWorkplaceSeed(repositories: [RepositoryConfig]) -> WorkplaceCreateSeed {
        guard screenshotScene == .createWorkplace else {
            return .empty
        }

        let selectedNames = Set(createSelectedRepositoryNames)
        let selectedIDs = Set(
            repositories
                .filter { selectedNames.contains($0.repoName) }
                .map(\.id)
        )

        return WorkplaceCreateSeed(
            name: createWorkplaceName ?? "",
            branch: createWorkplaceBranch ?? "",
            selectedRepositoryIDs: selectedIDs
        )
    }

    private static func appSupportDirectory(from environment: [String: String]) -> URL? {
        guard let path = trimmedValue(environment["CCSPACE_APP_SUPPORT_DIR"]) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func screenshotScene(from environment: [String: String]) -> CCSpaceScreenshotScene? {
        guard let rawValue = trimmedValue(environment["CCSPACE_SCREENSHOT_SCENE"]) else {
            return nil
        }
        return CCSpaceScreenshotScene(rawValue: rawValue)
    }

    private static func windowSize(from environment: [String: String]) -> CGSize? {
        guard let rawValue = trimmedValue(environment["CCSPACE_WINDOW_SIZE"]) else {
            return nil
        }

        let separators = CharacterSet(charactersIn: "xX,")
        let components = rawValue
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private static func trimmedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func csvValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
