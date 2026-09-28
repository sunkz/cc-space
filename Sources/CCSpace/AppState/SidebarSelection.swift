import Foundation

enum SidebarSelection: Hashable {
    case route(AppRoute)
    case workplace(UUID)
}
