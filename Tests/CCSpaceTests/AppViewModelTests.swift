import XCTest
@testable import CCSpace

final class AppViewModelTests: XCTestCase {
    func test_availableRoutesDoNotIncludeStandaloneRepositories() {
        XCTAssertEqual(AppRoute.allCases.map(\.rawValue), ["settings", "workplaces"])
    }

    @MainActor
    func test_defaultsToSettingsAndNoSelectedWorkplace() {
        let model = AppViewModel()

        XCTAssertEqual(model.route, .settings)
        XCTAssertNil(model.selectedWorkplaceID)
        XCTAssertEqual(model.sidebarSelection, .route(.settings))
    }

    @MainActor
    func test_sidebarSelectionMapsCurrentRoute() {
        let model = AppViewModel()

        model.showRoute(.settings)

        XCTAssertEqual(model.sidebarSelection, .route(.settings))
    }

    @MainActor
    func test_showWorkplaceUpdatesRouteAndSelection() {
        let model = AppViewModel()
        let workplaceID = UUID()

        model.showWorkplace(workplaceID)

        XCTAssertEqual(model.route, .workplaces)
        XCTAssertEqual(model.selectedWorkplaceID, workplaceID)
        XCTAssertEqual(model.sidebarSelection, .workplace(workplaceID))
    }

    @MainActor
    func test_settingSidebarSelectionToWorkplaceUpdatesRouteAndSelection() {
        let model = AppViewModel()
        let workplaceID = UUID()

        model.sidebarSelection = .workplace(workplaceID)

        XCTAssertEqual(model.route, .workplaces)
        XCTAssertEqual(model.selectedWorkplaceID, workplaceID)
    }

    @MainActor
    func test_settingSidebarSelectionToRouteClearsSelectedWorkplace() {
        let model = AppViewModel()

        model.showWorkplace(UUID())
        model.showRoute(.settings)

        XCTAssertEqual(model.route, .settings)
        XCTAssertNil(model.selectedWorkplaceID)
        XCTAssertEqual(model.sidebarSelection, .route(.settings))
    }

    /// 启动恢复降级(上次在工作区页但选中项缺失/非法/已删)只切路由:
    /// 不得回调 onSelectedWorkplaceChange(nil),否则 500ms 防抖后
    /// lastSelectedWorkplaceID 被持久化成 nil——工作区记录本轮刚被损坏重置时,
    /// 单点损坏会级联改写另一份健康的 settings.json(见 RootSplitView.restoreLastSelectedRoute)。
    @MainActor
    func test_showRouteWithoutSelectionNotificationDoesNotPersistNilSelection() {
        let model = AppViewModel()
        var persistedRoutes: [AppRoute] = []
        var persistedSelections: [UUID?] = []
        model.onRouteChange = { persistedRoutes.append($0) }
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        model.showRoute(.workplaces, notifySelectionChange: false)

        XCTAssertEqual(model.route, .workplaces)
        XCTAssertNil(model.selectedWorkplaceID)
        XCTAssertEqual(persistedRoutes, [.workplaces], "路由镜像照常更新(值本就是 workplaces)")
        XCTAssertTrue(persistedSelections.isEmpty, "降级不得把 nil 写回 lastSelectedWorkplaceID")
    }

    /// 默认仍通知选中变化:运行期删除工作区等场景持久化 nil 才是事实。
    @MainActor
    func test_showRouteNotifiesSelectionChangeByDefault() {
        let model = AppViewModel()
        var persistedSelections: [UUID?] = []
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        model.showRoute(.settings)

        XCTAssertEqual(persistedSelections, [nil])
    }

    /// 降级路径的唯一入口:内部固定 `notifySelectionChange: false`。
    /// 若有人把它改回默认 true(或改成裸 showRoute),本测试变红。
    @MainActor
    func test_showDegradedRouteNeverPersistsNilSelection() {
        let model = AppViewModel()
        var persistedRoutes: [AppRoute] = []
        var persistedSelections: [UUID?] = []
        model.onRouteChange = { persistedRoutes.append($0) }
        model.onSelectedWorkplaceChange = { persistedSelections.append($0) }

        model.showDegradedRoute(.workplaces)

        XCTAssertEqual(model.route, .workplaces)
        XCTAssertNil(model.selectedWorkplaceID)
        XCTAssertEqual(persistedRoutes, [.workplaces], "路由镜像照常更新")
        XCTAssertTrue(persistedSelections.isEmpty, "降级不得把 nil 写回 lastSelectedWorkplaceID")
    }
}
