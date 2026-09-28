import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var route: AppRoute = .settings
    @Published private(set) var selectedWorkplaceID: UUID?

    /// 路由变化的持久化回调,由组合根(RootSplitView)在 `onAppear` 注入
    /// (见 `bindRoutePersistenceCallbacks`:init 时 SwiftUI 实际持有的 SettingsStore
    /// 还在 StateObject 的 autoclosure 里,提前构造实例正是要消灭的重复读盘)。
    /// 写 settings.json 镜像的职责收在 AppViewModel 内,View 层只负责渲染,
    /// 避免持久化逻辑散落在视图修饰链里随渲染路径漂移。
    var onRouteChange: ((AppRoute) -> Void)?
    var onSelectedWorkplaceChange: ((UUID?) -> Void)?

    /// 切换路由并清空工作区选中。
    /// - Parameter notifySelectionChange: 是否回调 `onSelectedWorkplaceChange(nil)`
    ///   (即把 `lastSelectedWorkplaceID` 持久化成 nil)。启动恢复"降级到列表页"
    ///   (上次选中项缺失/非法/已删)时传 false:那往往是本轮工作区记录被损坏重置的
    ///   结果,落盘 nil 会级联改写设置文件(旧版本该分支也是只切路由不写)。
    func showRoute(_ route: AppRoute, notifySelectionChange: Bool = true) {
        self.route = route
        selectedWorkplaceID = nil
        onRouteChange?(route)
        if notifySelectionChange {
            onSelectedWorkplaceChange?(nil)
        }
    }

    /// 启动恢复"降级到列表页"的专用入口:只切路由,固定不回调
    /// `onSelectedWorkplaceChange`(即不把 nil 回写 `lastSelectedWorkplaceID`)。
    /// 单独成入口而不是让调用方记得传 `notifySelectionChange: false`,
    /// 是为了把"写错参数"的自由度消掉——写成默认值的后果是把健康文件里的
    /// 上次选中项覆写成 nil(见 `RouteRestoreSupport.apply`)。
    func showDegradedRoute(_ route: AppRoute) {
        showRoute(route, notifySelectionChange: false)
    }

    func showWorkplace(_ workplaceID: UUID) {
        route = .workplaces
        selectedWorkplaceID = workplaceID
        onRouteChange?(.workplaces)
        onSelectedWorkplaceChange?(workplaceID)
    }

    var sidebarSelection: SidebarSelection? {
        get {
            if let selectedWorkplaceID {
                return .workplace(selectedWorkplaceID)
            }
            return .route(route)
        }
        set {
            switch newValue {
            case .route(let route):
                showRoute(route)
            case .workplace(let workplaceID):
                showWorkplace(workplaceID)
            case nil:
                // getter 恒不返回 nil,但侧栏 List(selection:) 在清空选中时会写入
                // nil——保持现状(路由不变),不是可删的死分支。
                break
            }
        }
    }
}
