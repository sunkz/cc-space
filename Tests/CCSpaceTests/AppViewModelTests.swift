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
}
