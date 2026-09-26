import CoreGraphics
import Foundation
import SwiftUI

/// 侧栏工作区列表的排序方式。
enum WorkplaceSortMode: String, CaseIterable, Identifiable, Sendable {
    case name
    case createdAt
    case branch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "按名称"
        case .createdAt: "按创建时间"
        case .branch: "按分支"
        }
    }
}

struct SidebarPresentationState {
    let activeWorkplaces: [Workplace]
    let archivedWorkplaces: [Workplace]

    init(
        workplaces: [Workplace],
        searchText: String,
        sortMode: WorkplaceSortMode = .name
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredWorkplaces: [Workplace]
        if trimmedSearchText.isEmpty {
            filteredWorkplaces = workplaces
        } else {
            filteredWorkplaces = workplaces.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearchText)
                || ($0.branch ?? "").localizedCaseInsensitiveContains(trimmedSearchText)
            }
        }

        activeWorkplaces = filteredWorkplaces
            .filter { !$0.isArchived }
            .sorted { Self.compareActiveWorkplaces($0, $1, sortMode: sortMode) }
        archivedWorkplaces = filteredWorkplaces
            .filter(\.isArchived)
            .sorted { Self.compareBySortMode($0, $1, sortMode: sortMode) }
    }

    /// 置顶的工作区始终排最前,其余按所选方式排序。
    private static func compareActiveWorkplaces(
        _ lhs: Workplace,
        _ rhs: Workplace,
        sortMode: WorkplaceSortMode
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        return compareBySortMode(lhs, rhs, sortMode: sortMode)
    }

    private static func compareBySortMode(
        _ lhs: Workplace,
        _ rhs: Workplace,
        sortMode: WorkplaceSortMode
    ) -> Bool {
        switch sortMode {
        case .name:
            return compareNames(lhs, rhs)
        case .createdAt:
            // 新创建的排前面;时间相同回退名称,保证稳定排序。
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return compareNames(lhs, rhs)
        case .branch:
            // 分支按字母排序,未设置分支的排在最后。
            if let lhsBranch = normalizedBranch(lhs) {
                if let rhsBranch = normalizedBranch(rhs) {
                    let comparison = lhsBranch.localizedStandardCompare(rhsBranch)
                    if comparison != .orderedSame {
                        return comparison == .orderedAscending
                    }
                } else {
                    return true
                }
            } else if normalizedBranch(rhs) != nil {
                return false
            }
            return compareNames(lhs, rhs)
        }
    }

    private static func normalizedBranch(_ workplace: Workplace) -> String? {
        guard let branch = workplace.branch?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            branch.isEmpty == false else { return nil }
        return branch
    }

    private static func compareNames(_ lhs: Workplace, _ rhs: Workplace) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return comparison == .orderedAscending
    }
}

/// 工作区创建时间的相对文案。
/// 递进规则与输出格式统一委托给 `Date.relativeDescription`
/// (全 App 相对时间唯一实现),避免多套格式漂移。
enum WorkplaceRelativeTimeFormatter {
    static func creationText(
        createdAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        createdAt.relativeDescription(now: now, calendar: calendar)
    }

    /// 绝对日期:同年省略年份,跨年带年份。
    static func absoluteDateText(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let month = dateComponents.month ?? 0
        let day = dateComponents.day ?? 0
        if dateComponents.year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return "\(dateComponents.year ?? 0)年\(month)月\(day)日"
    }
}

struct SidebarWorkplaceRowPresentationState {
    /// 置顶图标列宽与 accessory 组内间距是纯布局常量,直接以静态常量暴露,
    /// 不再复制到实例字段(此前实例值恒等于同名静态量,纯冗余)。
    static let pinIndicatorColumnWidth: CGFloat = 12
    static let accessorySpacing: CGFloat = 4

    let showsPinnedIndicator: Bool
    let statusIndicatorColor: Color?
    let creationTimeText: String

    init(
        workplace: Workplace,
        hasFailed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        showsPinnedIndicator = workplace.isPinned && !workplace.isArchived
        statusIndicatorColor = hasFailed ? .red : nil
        creationTimeText = WorkplaceRelativeTimeFormatter.creationText(
            createdAt: workplace.createdAt,
            now: now,
            calendar: calendar
        )
    }
}

/// 悬停滚动(跑马灯)文本的展示决策(纯逻辑,便于测试)。
struct MarqueeTextPresentationState: Equatable {
    /// 低于该溢出量不值得滚动。
    static let minOverflow: CGFloat = 4
    /// 滚动终点额外留白,保证末尾完整可见。
    static let tailPadding: CGFloat = 8
    /// 滚动速度(点/秒)。
    static let speed: Double = 30
    /// 重启滚动循环的距离变化阈值:测量宽度亚点级抖动不值得打断滚动。
    static let distanceRestartThreshold: CGFloat = 1

    let shouldScroll: Bool
    let distance: CGFloat
    let duration: TimeInterval

    init(textWidth: CGFloat?, containerWidth: CGFloat?, isActive: Bool) {
        let overflow: CGFloat
        if let textWidth, let containerWidth {
            overflow = textWidth - containerWidth
        } else {
            overflow = 0
        }
        shouldScroll = isActive && overflow > Self.minOverflow
        distance = max(overflow, 0) + Self.tailPadding
        duration = max(Double(distance) / Self.speed, 0.5)
    }
}

/// 悬停时水平滚动展示完整文案的单行文本;未激活或未溢出时表现为普通截断文本。
/// 字体与颜色由调用方经环境值注入。
struct CCSpaceMarqueeText: View {
    let text: String
    let isActive: Bool

    @State private var textWidth: CGFloat?
    @State private var containerWidth: CGFloat?
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?
    /// 当前滚动循环所依据的计划;nil 表示未在滚动。onDisappear 随任务一并清理。
    @State private var activeScrollPlan: MarqueeTextPresentationState?

    private var presentationState: MarqueeTextPresentationState {
        MarqueeTextPresentationState(
            textWidth: textWidth,
            containerWidth: containerWidth,
            isActive: isActive
        )
    }

    var body: some View {
        // 截断版文本是布局锚点(宽度恒为可用宽度,不挤占行内其他元素);
        // 滚动版作为 overlay 叠加其上,不参与布局,仅靠 offset 与 clipped 滚动展示。
        // 滚动激活时锚点只留占位不绘制,避免两层文字重叠。
        Text(text)
            .lineLimit(1)
            .opacity(presentationState.shouldScroll ? 0 : 1)
            .overlay(alignment: .leading) {
                if presentationState.shouldScroll {
                    Text(text)
                        .fixedSize()
                        .offset(x: offset)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(measureContainer.allowsHitTesting(false))
            .background(measureText.allowsHitTesting(false))
            .onChange(of: presentationState) { _, newState in
                handleScrollPlanChange(newState)
            }
            .onDisappear {
                scrollTask?.cancel()
                activeScrollPlan = nil
            }
    }

    /// 隐藏的等宽测量层:取文案固有宽度。仅测量不绘制,避免与正文形成重影。
    private var measureText: some View {
        Text(text)
            .fixedSize()
            .opacity(0)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            textWidth = newWidth
                        }
                }
            )
    }

    private var measureContainer: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in
                    containerWidth = newWidth
                }
        }
    }

    /// 仅在滚动需求实质变化时重启循环:shouldScroll 翻转,或滚动距离变化
    /// 超过 distanceRestartThreshold(如侧栏宽度调整)。测量宽度的亚点级抖动
    /// 同样会触发 onChange,若每次都 cancel + 复位 offset,滚动会被不断打断。
    private func handleScrollPlanChange(_ newState: MarqueeTextPresentationState) {
        guard let current = activeScrollPlan else {
            // 未在滚动:需要滚动才启动。
            guard newState.shouldScroll else { return }
            activeScrollPlan = newState
            startScrolling(plan: newState)
            return
        }
        if newState.shouldScroll != current.shouldScroll {
            // 开关翻转:启动或停止(停止时复位 offset)。
            activeScrollPlan = newState.shouldScroll ? newState : nil
            if newState.shouldScroll {
                startScrolling(plan: newState)
            } else {
                stopScrolling()
            }
        } else if newState.shouldScroll,
                  abs(newState.distance - current.distance)
                  > MarqueeTextPresentationState.distanceRestartThreshold {
            // 仍在滚动但距离实质变化:按新计划重启。
            activeScrollPlan = newState
            startScrolling(plan: newState)
        }
    }

    /// 往返滚动:激活后立即滚向末尾,两端稍作停留,循环至取消。
    private func startScrolling(plan: MarqueeTextPresentationState) {
        scrollTask?.cancel()
        offset = 0
        let distance = plan.distance
        let duration = plan.duration
        scrollTask = Task { @MainActor in
            while Task.isCancelled == false {
                withAnimation(.linear(duration: duration)) {
                    offset = -distance
                }
                try? await Task.sleep(for: .seconds(duration + 1.0))
                guard Task.isCancelled == false else { break }
                withAnimation(.linear(duration: duration)) {
                    offset = 0
                }
                try? await Task.sleep(for: .seconds(duration + 1.2))
            }
        }
    }

    private func stopScrolling() {
        scrollTask?.cancel()
        scrollTask = nil
        withAnimation(.easeOut(duration: 0.2)) {
            offset = 0
        }
    }
}

struct SidebarWorkplaceRowView: View {
    let workplace: Workplace
    let hasFailed: Bool
    let branchName: String?
    let onTogglePinned: (Workplace) -> Void
    let onDuplicateWorkplace: (Workplace) -> Void
    let onToggleArchived: (Workplace) -> Void

    @State private var isHovered = false

    private var rowPresentationState: SidebarWorkplaceRowPresentationState {
        SidebarWorkplaceRowPresentationState(
            workplace: workplace,
            hasFailed: hasFailed
        )
    }

    /// 次级说明行:创建时间在前、分支名在后,无分支时仅显示创建时间。
    private var captionText: String {
        if let branchName, branchName.isEmpty == false {
            return "\(rowPresentationState.creationTimeText) · \(branchName)"
        }
        return rowPresentationState.creationTimeText
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workplace.isArchived ? "archivebox" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(workplace.name)
                    .lineLimit(1)
                CCSpaceMarqueeText(text: captionText, isActive: isHovered)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: SidebarWorkplaceRowPresentationState.accessorySpacing) {
                if !workplace.isArchived {
                    Button {
                        onTogglePinned(workplace)
                    } label: {
                        Group {
                            if workplace.isPinned {
                                Image(systemName: isHovered ? "pin.slash" : "pin.fill")
                            } else {
                                Image(systemName: "pin")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: SidebarWorkplaceRowPresentationState.pinIndicatorColumnWidth)
                    }
                    .buttonStyle(.plain)
                    .opacity(workplace.isPinned || isHovered ? 1 : 0)
                    .accessibilityLabel(workplace.isPinned ? "取消置顶" : "置顶工作区")
                }
                if let color = rowPresentationState.statusIndicatorColor {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            // macOS 26 右键菜单默认不渲染 Label 的 SF Symbol 图标,显式要求标题+图标。
            Group {
                Button {
                    onTogglePinned(workplace)
                } label: {
                    Label(
                        workplace.isPinned ? "取消置顶" : "置顶工作区",
                        systemImage: workplace.isPinned ? "pin.slash" : "pin"
                    )
                }

                Button {
                    onDuplicateWorkplace(workplace)
                } label: {
                    Label("复制工作区", systemImage: "doc.on.doc")
                }

                Button {
                    onToggleArchived(workplace)
                } label: {
                    Label(
                        workplace.isArchived ? "取消归档" : "归档工作区",
                        systemImage: workplace.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
