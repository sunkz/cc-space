import Foundation

/// 路由枚举。`CaseIterable` 保留:AppViewModelTests 用 `allCases` 断言
/// 可选路由集合(勿删);`Identifiable` 供选择态 tag/ForEach 使用。
enum AppRoute: String, CaseIterable, Identifiable {
    case settings
    case workplaces

    var id: String { rawValue }
}
