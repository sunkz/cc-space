import CoreGraphics
import Foundation

enum CCSpaceScreenshotScene: String, Equatable {
    case settingsOverview = "settings-overview"
    case workplaceDetail = "workplace-detail"
    case createWorkplace = "create-workplace"
}

/// 启动时"恢复上次所在页面"的纯决策(便于测试,见 RootSplitViewSupportTests)。
enum RouteRestoreSupport {
    struct Selection: Equatable {
        let route: AppRoute
        /// 恢复出的工作区;上次在工作区页但选中项缺失/非法/工作区已删时为 nil,
        /// 此时降级为"工作区列表",而不是什么都不做落回默认设置页。
        /// 注意降级只切路由:经 `apply(_:to:)` 固定走 `showDegradedRoute`,
        /// 不得把 nil 回写 `lastSelectedWorkplaceID`,否则会级联改写设置文件。
        let workplaceID: UUID?
    }

    /// 持久化路由缺失或非法时返回 nil(调用方落到默认路由)。
    static func restoredSelection(
        lastSelectedRoute: String?,
        lastSelectedWorkplaceID: String?,
        workplaces: [Workplace]
    ) -> Selection? {
        // 经 AppRoute(rawValue:) 校验而非裸字符串比较:持久化值可能来自
        // 旧版本/手改文件,非法值直接忽略。
        guard let lastSelectedRoute,
              let route = AppRoute(rawValue: lastSelectedRoute) else { return nil }
        switch route {
        case .settings:
            return Selection(route: .settings, workplaceID: nil)
        case .workplaces:
            guard let idString = lastSelectedWorkplaceID,
                  let workplaceID = UUID(uuidString: idString),
                  workplaces.contains(where: { $0.id == workplaceID }) else {
                return Selection(route: .workplaces, workplaceID: nil)
            }
            return Selection(route: .workplaces, workplaceID: workplaceID)
        }
    }

    /// 把恢复出的选中项落到 ViewModel(降级接线的唯一入口,便于测试锁住)。
    ///
    /// 降级分支(`.workplaces` + nil)固定走 `showDegradedRoute`,不回写
    /// `lastSelectedWorkplaceID`;正常分支照常通知选中变化。
    @MainActor
    static func apply(_ selection: Selection, to viewModel: AppViewModel) {
        switch selection.route {
        case .settings:
            viewModel.showRoute(.settings)
        case .workplaces:
            if let workplaceID = selection.workplaceID {
                viewModel.showWorkplace(workplaceID)
            } else {
                viewModel.showDegradedRoute(.workplaces)
            }
        }
    }
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

extension WorkplaceCreateSeed {
    static func duplicate(from workplace: Workplace, existingNames: [String] = []) -> WorkplaceCreateSeed {
        let baseName = "\(workplace.name) 副本"
        var candidateName = baseName
        if existingNames.contains(candidateName) {
            var counter = 2
            repeat {
                candidateName = "\(workplace.name) 副本 \(counter)"
                counter += 1
            } while existingNames.contains(candidateName)
        }
        return WorkplaceCreateSeed(
            name: candidateName,
            branch: workplace.branch ?? "",
            selectedRepositoryIDs: Set(workplace.selectedRepositoryIDs)
        )
    }
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

    /// 解析应用支撑目录:环境变量覆盖优先;否则 Application Support/CCSpace,
    /// 极端情况下(如沙盒配置异常)回退用户主目录下的 CCSpace 目录而不是启动即崩。
    func resolvedAppSupportDirectory() -> URL {
        if let appSupportDirectory { return appSupportDirectory }
        let appSupportBase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupportBase.appendingPathComponent("CCSpace", isDirectory: true)
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
