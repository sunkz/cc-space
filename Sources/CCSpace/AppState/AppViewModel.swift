import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var route: AppRoute = .settings
    @Published private(set) var selectedWorkplaceID: UUID?

    func showRoute(_ route: AppRoute) {
        self.route = route
        selectedWorkplaceID = nil
    }

    func showWorkplace(_ workplaceID: UUID) {
        route = .workplaces
        selectedWorkplaceID = workplaceID
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
