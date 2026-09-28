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

    // MARK: - 排序方式

    func test_sortByCreatedAtPutsNewestFirstWhilePinnedStaysOnTop() {
        let oldest = makeWorkplace(name: "Oldest", isPinned: false, isArchived: false, createdAt: makeDate(2026, 1, 1))
        let newest = makeWorkplace(name: "Newest", isPinned: false, isArchived: false, createdAt: makeDate(2026, 8, 1))
        let middle = makeWorkplace(name: "Middle", isPinned: false, isArchived: false, createdAt: makeDate(2026, 4, 1))
        let pinned = makeWorkplace(name: "Pinned", isPinned: true, isArchived: false, createdAt: makeDate(2026, 2, 1))

        let presentationState = SidebarPresentationState(
            workplaces: [oldest, newest, middle, pinned],
            searchText: "",
            sortMode: .createdAt
        )

        XCTAssertEqual(presentationState.activeWorkplaces.map(\.name), ["Pinned", "Newest", "Middle", "Oldest"])
    }

    func test_sortByBranchOrdersAlphabeticallyWithBranchlessLast() {
        let develop = makeWorkplace(name: "Gamma", isPinned: false, isArchived: false, branch: "develop")
        let main = makeWorkplace(name: "Beta", isPinned: false, isArchived: false, branch: "main")
        let feature = makeWorkplace(name: "Alpha", isPinned: false, isArchived: false, branch: "feature/x")
        let branchless = makeWorkplace(name: "Delta", isPinned: false, isArchived: false)

        let presentationState = SidebarPresentationState(
            workplaces: [develop, main, feature, branchless],
            searchText: "",
            sortMode: .branch
        )

        XCTAssertEqual(
            presentationState.activeWorkplaces.map(\.name),
            ["Gamma", "Alpha", "Beta", "Delta"]
        )
    }

    func test_archivedWorkplacesFollowSelectedSortMode() {
        let older = makeWorkplace(name: "Older", isPinned: false, isArchived: true, createdAt: makeDate(2026, 1, 1))
        let newer = makeWorkplace(name: "Newer", isPinned: false, isArchived: true, createdAt: makeDate(2026, 8, 1))

        let presentationState = SidebarPresentationState(
            workplaces: [older, newer],
            searchText: "",
            sortMode: .createdAt
        )

        XCTAssertEqual(presentationState.archivedWorkplaces.map(\.name), ["Newer", "Older"])
    }

    func test_sortModeTitles() {
        XCTAssertEqual(WorkplaceSortMode.name.title, "按名称")
        XCTAssertEqual(WorkplaceSortMode.createdAt.title, "按创建时间")
        XCTAssertEqual(WorkplaceSortMode.branch.title, "按分支")
        XCTAssertEqual(WorkplaceSortMode.allCases.map(\.rawValue), ["name", "createdAt", "branch"])
    }

    func test_rowAccessoryUsesCompactLayout() {
        XCTAssertEqual(SidebarWorkplaceRowPresentationState.pinIndicatorColumnWidth, 12)
        XCTAssertEqual(SidebarWorkplaceRowPresentationState.accessorySpacing, 4)
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

    // MARK: - 创建时间相对文案

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0
    ) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func test_creationTextEscalatesFromJustNowToDays() {
        let calendar = utcCalendar
        let now = makeDate(2026, 8, 19, 12, 0)

        XCTAssertEqual(WorkplaceRelativeTimeFormatter.creationText(createdAt: now, now: now, calendar: calendar), "刚刚")
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: now.addingTimeInterval(-30), now: now, calendar: calendar),
            "刚刚"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 8, 19, 11, 55), now: now, calendar: calendar),
            "5 分钟前"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 8, 19, 10, 0), now: now, calendar: calendar),
            "2 小时前"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 8, 18, 13, 0), now: now, calendar: calendar),
            "23 小时前"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 8, 18, 11, 0), now: now, calendar: calendar),
            "1 天前"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 7, 21, 0, 0), now: now, calendar: calendar),
            "29 天前"
        )
    }

    func test_creationTextFallsBackToAbsoluteDateBeyondThirtyDays() {
        let calendar = utcCalendar
        let now = makeDate(2026, 8, 19, 12, 0)

        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2026, 7, 19, 0, 0), now: now, calendar: calendar),
            "7月19日"
        )
        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: makeDate(2025, 12, 1, 0, 0), now: now, calendar: calendar),
            "2025年12月1日"
        )
    }

    func test_creationTextTreatsFutureTimestampAsJustNow() {
        let calendar = utcCalendar
        let now = makeDate(2026, 8, 19, 12, 0)

        XCTAssertEqual(
            WorkplaceRelativeTimeFormatter.creationText(createdAt: now.addingTimeInterval(600), now: now, calendar: calendar),
            "刚刚"
        )
    }

    func test_rowPresentationStateExposesCreationTimeText() {
        let calendar = utcCalendar
        let createdAt = makeDate(2026, 8, 19, 9, 30)
        let state = SidebarWorkplaceRowPresentationState(
            workplace: Workplace(
                id: UUID(),
                name: "Recent",
                path: "/tmp/Recent",
                selectedRepositoryIDs: [],
                branch: nil,
                isPinned: false,
                isArchived: false,
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            hasFailed: false,
            now: makeDate(2026, 8, 19, 12, 0),
            calendar: calendar
        )

        XCTAssertEqual(state.creationTimeText, "2 小时前")
    }

    // MARK: - 悬停滚动(跑马灯)

    func test_marqueeStateRequiresHoverAndMeaningfulOverflow() {
        // 未悬停:即使溢出也不滚动。
        XCTAssertFalse(
            MarqueeTextPresentationState(textWidth: 200, containerWidth: 100, isActive: false).shouldScroll
        )
        // 悬停但溢出量不足(≤4pt):不值得滚动。
        XCTAssertFalse(
            MarqueeTextPresentationState(textWidth: 104, containerWidth: 100, isActive: true).shouldScroll
        )
        // 宽度未知(首次布局前):不滚动。
        XCTAssertFalse(
            MarqueeTextPresentationState(textWidth: nil, containerWidth: nil, isActive: true).shouldScroll
        )
        XCTAssertFalse(
            MarqueeTextPresentationState(textWidth: 200, containerWidth: nil, isActive: true).shouldScroll
        )
        // 未溢出:不滚动。
        XCTAssertFalse(
            MarqueeTextPresentationState(textWidth: 80, containerWidth: 100, isActive: true).shouldScroll
        )
    }

    func test_marqueeStateDistanceIncludesTailPadding() {
        let state = MarqueeTextPresentationState(textWidth: 160, containerWidth: 100, isActive: true)

        XCTAssertTrue(state.shouldScroll)
        XCTAssertEqual(state.distance, 68)  // 溢出 60 + 尾部留白 8
        XCTAssertEqual(state.duration, 68.0 / 30.0, accuracy: 0.001)
    }

    func test_marqueeStateDurationHasLowerBound() {
        // 溢出刚过阈值:距离很小,时长不低于 0.5s。
        let state = MarqueeTextPresentationState(textWidth: 105, containerWidth: 100, isActive: true)

        XCTAssertTrue(state.shouldScroll)
        XCTAssertEqual(state.distance, 13)
        XCTAssertEqual(state.duration, 0.5, accuracy: 0.001)
    }

    private func makeWorkplace(
        name: String,
        repositoryCount: Int = 0,
        isPinned: Bool,
        isArchived: Bool,
        branch: String? = nil,
        createdAt: Date = .distantPast
    ) -> Workplace {
        Workplace(
            id: UUID(),
            name: name,
            path: "/tmp/\(name)",
            selectedRepositoryIDs: Array(repeating: UUID(), count: repositoryCount),
            branch: branch,
            isPinned: isPinned,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: .distantPast
        )
    }
}
