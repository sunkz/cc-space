import Foundation

enum AppRoute: String, CaseIterable, Identifiable {
    case settings
    case workplaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings:
            return "设置"
        case .workplaces:
            return "工作区列表"
        }
    }

    var systemImage: String {
        switch self {
        case .settings:
            return "gearshape"
        case .workplaces:
            return "square.grid.2x2"
        }
    }
}
