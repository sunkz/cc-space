import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var route: AppRoute = .settings
    @Published private(set) var selectedWorkplaceID: UUID?

    /// 路由变化的持久化回调,由组合根(RootSplitView)创建时注入。
    /// 写 settings.json 镜像的职责收在 AppViewModel 内,View 层只负责渲染,
    /// 避免持久化逻辑散落在视图修饰链里随渲染路径漂移。
    var onRouteChange: ((AppRoute) -> Void)?
    var onSelectedWorkplaceChange: ((UUID?) -> Void)?

    func showRoute(_ route: AppRoute) {
        self.route = route
        selectedWorkplaceID = nil
        onRouteChange?(route)
        onSelectedWorkplaceChange?(nil)
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
                break
            }
        }
    }
}
