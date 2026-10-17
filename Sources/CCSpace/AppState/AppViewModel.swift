import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var route: AppRoute = .settings
    @Published private(set) var selectedWorkplaceID: UUID?

    /// 路由变化回调,由组合根(RootSplitView)在 `onAppear` 注入:init 时 SettingsStore 还在
    /// StateObject 的 autoclosure 里,提前构造会造成重复读盘。写 settings.json 只在本类型内。
    var onRouteChange: ((AppRoute) -> Void)?
    var onSelectedWorkplaceChange: ((UUID?) -> Void)?

    /// notifySelectionChange=false 只用于启动恢复"降级到列表页"(上次选中项缺失/非法/已删):
    /// 那往往是本轮记录被损坏重置的结果,把 nil 落盘会级联改写设置文件。
    func showRoute(_ route: AppRoute, notifySelectionChange: Bool = true) {
        // 刻意不做"值未变就提前返回"的空操作守卫:内存态与设置文件里已持久化的值可能不同,守卫会
        // 拦掉回调,文件残留的 lastSelectedWorkplaceID 会让下次启动直接开进那个工作区(幽灵状态)。
        self.route = route
        selectedWorkplaceID = nil
        onRouteChange?(route)
        if notifySelectionChange {
            onSelectedWorkplaceChange?(nil)
        }
    }

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
                // 侧栏 List(selection:) 清空选中时会写入 nil(getter 恒不返回 nil):保持现状,不是死分支。
                break
            }
        }
    }
}
