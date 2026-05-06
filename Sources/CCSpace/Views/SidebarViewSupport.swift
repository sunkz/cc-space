import CoreGraphics
import Foundation

struct SidebarPresentationState {
    let activeWorkplaces: [Workplace]
    let archivedWorkplaces: [Workplace]

    init(workplaces: [Workplace], searchText: String) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredWorkplaces: [Workplace]
        if trimmedSearchText.isEmpty {
            filteredWorkplaces = workplaces
        } else {
            filteredWorkplaces = workplaces.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearchText)
            }
        }

        activeWorkplaces = filteredWorkplaces
            .filter { !$0.isArchived }
            .sorted(by: Self.compareActiveWorkplaces)
        archivedWorkplaces = filteredWorkplaces
            .filter(\.isArchived)
            .sorted(by: Self.compareArchivedWorkplaces)
    }

    private static func compareActiveWorkplaces(_ lhs: Workplace, _ rhs: Workplace) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        return compareNames(lhs, rhs)
    }

    private static func compareArchivedWorkplaces(_ lhs: Workplace, _ rhs: Workplace) -> Bool {
        compareNames(lhs, rhs)
    }

    private static func compareNames(_ lhs: Workplace, _ rhs: Workplace) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return comparison == .orderedAscending
    }
}

struct SidebarWorkplaceRowPresentationState {
    static let pinIndicatorColumnWidth: CGFloat = 12
    static let repositoryCountColumnWidth: CGFloat = 20
    static let accessorySpacing: CGFloat = 4

    let showsPinnedIndicator: Bool
    let repositoryCountText: String
    let pinIndicatorColumnWidth: CGFloat
    let repositoryCountColumnWidth: CGFloat
    let accessorySpacing: CGFloat

    init(workplace: Workplace) {
        showsPinnedIndicator = workplace.isPinned && !workplace.isArchived
        repositoryCountText = "\(workplace.selectedRepositoryIDs.count)"
        pinIndicatorColumnWidth = Self.pinIndicatorColumnWidth
        repositoryCountColumnWidth = Self.repositoryCountColumnWidth
        accessorySpacing = Self.accessorySpacing
    }
}
