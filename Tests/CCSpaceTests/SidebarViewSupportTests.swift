import XCTest
@testable import CCSpace

final class SidebarViewSupportTests: XCTestCase {
    func test_pinnedActiveWorkplacesAppearBeforeRegularOnes() {
        let regular = makeWorkplace(name: "Alpha", isPinned: false, isArchived: false)
        let pinned = makeWorkplace(name: "Beta", isPinned: true, isArchived: false)

        let presentationState = SidebarPresentationState(
            workplaces: [regular, pinned],
            searchText: ""
        )

        XCTAssertEqual(presentationState.activeWorkplaces.map(\.name), ["Beta", "Alpha"])
        XCTAssertTrue(presentationState.archivedWorkplaces.isEmpty)
    }

    func test_archivedWorkplacesAreSeparatedAndSortedByName() {
        let active = makeWorkplace(name: "Main", isPinned: false, isArchived: false)
        let archivedB = makeWorkplace(name: "Zoo", isPinned: true, isArchived: true)
        let archivedA = makeWorkplace(name: "Archive", isPinned: false, isArchived: true)

        let presentationState = SidebarPresentationState(
            workplaces: [archivedB, active, archivedA],
            searchText: ""
        )

        XCTAssertEqual(presentationState.activeWorkplaces.map(\.name), ["Main"])
        XCTAssertEqual(presentationState.archivedWorkplaces.map(\.name), ["Archive", "Zoo"])
    }

    func test_rowAccessoryColumnsStayFixedAcrossDifferentRepositoryCounts() {
        let singleRepositoryWorkplace = makeWorkplace(
            name: "One",
            repositoryCount: 3,
            isPinned: true,
            isArchived: false
        )
        let manyRepositoriesWorkplace = makeWorkplace(
            name: "Many",
            repositoryCount: 42,
            isPinned: false,
            isArchived: false
        )

        let singleRepositoryState = SidebarWorkplaceRowPresentationState(workplace: singleRepositoryWorkplace, hasFailed: false)
        let manyRepositoriesState = SidebarWorkplaceRowPresentationState(workplace: manyRepositoriesWorkplace, hasFailed: false)

        XCTAssertEqual(singleRepositoryState.pinIndicatorColumnWidth, manyRepositoriesState.pinIndicatorColumnWidth)
        XCTAssertEqual(singleRepositoryState.repositoryCountColumnWidth, manyRepositoriesState.repositoryCountColumnWidth)
        XCTAssertEqual(singleRepositoryState.repositoryCountText, "3")
        XCTAssertEqual(manyRepositoriesState.repositoryCountText, "42")
    }

    func test_rowAccessoryUsesCompactTwoDigitLayout() {
        let state = SidebarWorkplaceRowPresentationState(
            workplace: makeWorkplace(name: "Pinned", repositoryCount: 42, isPinned: true, isArchived: false),
            hasFailed: false
        )

        XCTAssertEqual(state.pinIndicatorColumnWidth, 12)
        XCTAssertEqual(state.repositoryCountColumnWidth, 20)
        XCTAssertEqual(state.accessorySpacing, 4)
    }

    func test_rowAccessoryStateOnlyShowsPinnedIndicatorForActivePinnedWorkplace() {
        let pinnedActive = SidebarWorkplaceRowPresentationState(
            workplace: makeWorkplace(name: "Pinned", repositoryCount: 1, isPinned: true, isArchived: false),
            hasFailed: false
        )
        let pinnedArchived = SidebarWorkplaceRowPresentationState(
            workplace: makeWorkplace(name: "Archived", repositoryCount: 1, isPinned: true, isArchived: true),
            hasFailed: false
        )

        XCTAssertTrue(pinnedActive.showsPinnedIndicator)
        XCTAssertFalse(pinnedArchived.showsPinnedIndicator)
    }

    private func makeWorkplace(
        name: String,
        repositoryCount: Int = 0,
        isPinned: Bool,
        isArchived: Bool
    ) -> Workplace {
        Workplace(
            id: UUID(),
            name: name,
            path: "/tmp/\(name)",
            selectedRepositoryIDs: Array(repeating: UUID(), count: repositoryCount),
            branch: nil,
            isPinned: isPinned,
            isArchived: isArchived,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
