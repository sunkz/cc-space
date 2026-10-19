import AppKit
import CoreGraphics
import Foundation
import SwiftUI

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

/// 相对时间的递进规则与输出格式统一委托 `Date.relativeDescription`(全 App 唯一实现),避免多套格式漂移。
enum WorkplaceRelativeTimeFormatter {
    static func creationText(
        createdAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        createdAt.relativeDescription(now: now, calendar: calendar)
    }

    static func absoluteDateText(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        // year/month/day 任一分量取不到时退化到系统日期格式:`?? 0` 兜底会渲染出"0月0日"这种无法解读的文案。
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = dateComponents.year,
              let month = dateComponents.month,
              let day = dateComponents.day else {
            return Self.fallbackDateFormatter.string(from: date)
        }
        if year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return "\(year)年\(month)月\(day)日"
    }

    /// 日历分量缺失时的兜底格式(仅理论上非格里高利/受限日历会走到)。
    private static let fallbackDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct SidebarWorkplaceRowPresentationState {
    static let pinIndicatorColumnWidth: CGFloat = 12
    static let accessorySpacing: CGFloat = 4

    let statusIndicatorColor: Color?
    let creationTimeText: String

    init(
        workplace: Workplace,
        hasFailed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        statusIndicatorColor = hasFailed ? .red : nil
        creationTimeText = WorkplaceRelativeTimeFormatter.creationText(
            createdAt: workplace.createdAt,
            now: now,
            calendar: calendar
        )
    }
}

struct MarqueeTextPresentationState: Equatable {
    static let minOverflow: CGFloat = 4
    static let tailPadding: CGFloat = 8
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
        // 截断版文本是布局锚点(宽度恒为可用宽度,不挤占行内其他元素);滚动版作为 overlay 叠加其上,不参与布局。
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
            .background(measureContainerLayer)
            .background(measureTextLayer)
            .onChange(of: presentationState) { _, newState in
                handleScrollPlanChange(newState)
            }
            .onDisappear {
                scrollTask?.cancel()
                activeScrollPlan = nil
            }
    }

    /// 宽度只在真正会滚动时(hover)才有意义:`isActive == false` 时 shouldScroll 恒为 false,
    /// 测量层纯属白跑。GeometryReader 要参与每一次布局,37 行两枚就是 74 个,侧栏每次重渲染都付一遍。
    /// 挂/卸只改动这一行的背景层,宽度 @State 跨 hover 保留,再次 hover 时首轮求值即拿到旧宽度。
    @ViewBuilder
    private var measureContainerLayer: some View {
        if isActive {
            measureContainer.allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var measureTextLayer: some View {
        if isActive {
            measureText.allowsHitTesting(false)
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

    /// 仅在滚动需求实质变化时重启循环:shouldScroll 翻转,或滚动距离变化超过 distanceRestartThreshold。
    /// 测量宽度的亚点级抖动同样会触发 onChange,若每次都 cancel + 复位 offset,滚动会被不断打断。
    private func handleScrollPlanChange(_ newState: MarqueeTextPresentationState) {
        guard let current = activeScrollPlan else {
            guard newState.shouldScroll else { return }
            activeScrollPlan = newState
            startScrolling(plan: newState)
            return
        }
        if newState.shouldScroll != current.shouldScroll {
            activeScrollPlan = newState.shouldScroll ? newState : nil
            if newState.shouldScroll {
                startScrolling(plan: newState)
            } else {
                stopScrolling()
            }
        } else if newState.shouldScroll,
                  abs(newState.distance - current.distance)
                  > MarqueeTextPresentationState.distanceRestartThreshold {
            activeScrollPlan = newState
            startScrolling(plan: newState)
        }
    }

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
    /// 相对时间基准,由外层 body 每轮渲染求值一次后传入:逐行各取 Date() 会让同一屏文案跨在阈值两侧。
    let now: Date
    let branchName: String?
    let onTogglePinned: (Workplace) -> Void
    let onDuplicateWorkplace: (Workplace) -> Void
    let onToggleArchived: (Workplace) -> Void

    @State private var isHovered = false

    private var rowPresentationState: SidebarWorkplaceRowPresentationState {
        SidebarWorkplaceRowPresentationState(
            workplace: workplace,
            hasFailed: hasFailed,
            now: now
        )
    }

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
                    // opacity-0 只是视觉隐藏:命中区与无障碍元素仍在,不可见时须同时关掉命中与 VoiceOver,
                    // 否则会点空白误触置顶、读出屏幕上并不存在的按钮(置顶入口另有右键菜单,不因此丢失可达性)。
                    .allowsHitTesting(workplace.isPinned || isHovered)
                    .accessibilityHidden(workplace.isPinned || isHovered == false)
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

/// 鼠标点选工作区后,把键盘焦点从侧栏搜索框交回工作区列表。
///
/// 搜索框是 `.searchable(placement: .sidebar)`,SwiftUI 不给焦点绑定:一旦点过它,第一响应者就一直
/// 停在搜索框里——光标不停闪、后续敲的字符全进了搜索框。这里在选中项变化时主动接管。
///
/// 只在"搜索框仍然是第一响应者"时动手:用键盘从搜索框跳进列表时焦点早已离开,不该被抢回来;
/// 选中项变回 nil(切去设置页)也不接管,那是停止筛选、不是选完就走。
struct SidebarSearchFocusRelinquisher: NSViewRepresentable {
    /// 焦点交还的推迟量,见 `updateNSView`。
    static let handoffSettleDelay: TimeInterval = 0.2

    let selectedWorkplaceID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(lastSelectedWorkplaceID: selectedWorkplaceID)
    }

    func makeNSView(context: Context) -> NSView {
        // 只用来定位窗口与视图树,不参与命中:默认 NSView 会接住列表空白区的点击。
        ProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.lastSelectedWorkplaceID != selectedWorkplaceID else { return }
        coordinator.lastSelectedWorkplaceID = selectedWorkplaceID
        guard selectedWorkplaceID != nil else { return }
        // 接管要推迟到本轮视图更新之后:同步做读到的是点击前的旧第一响应者;
        // 而启动恢复选中项那一轮 SwiftUI 还在重建侧栏,立刻把刚建出来的列表设成第一响应者
        // 会让宿主窗口直接消失(实测:0ms 必现,≥200ms 两条路径都正常)。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffSettleDelay) { [weak nsView] in
            guard let nsView else { return }
            MainActor.assumeIsolated {
                Self.relinquishFocus(from: nsView)
            }
        }
    }

    @MainActor
    static func relinquishFocus(from probe: NSView) {
        guard let window = probe.window, isEditingSearchField(window.firstResponder) else { return }
        // 交回列表而不是单纯失焦:列表拿到第一响应者后,上下键还能继续切工作区
        // (resign 到窗口本身会把这条键盘导航一起弄丢,实测 ↓ 不再切换)。
        window.makeFirstResponder(nearestTableView(above: probe))
    }

    /// "正在编辑的是不是搜索框":文本编辑期间窗口的第一响应者是**字段编辑器**(`NSTextView`),
    /// 控件本身挂在它的 `delegate` 上(实测 `.searchable` 落的是 `AppKitSearchField`)。
    /// 只判 `firstResponder is NSSearchField` 恒假,整段接管会静默变成空操作。
    @MainActor
    static func isEditingSearchField(_ responder: NSResponder?) -> Bool {
        if responder is NSSearchField { return true }
        return (responder as? NSTextView)?.delegate is NSSearchField
    }

    /// 从探针逐级往上找**最近的**含 `NSTableView` 的祖先——SwiftUI 的 `List` 在 macOS 上由
    /// `NSTableView` 承载。只按窗口全量扫会抓到详情区/弹层里的表,拿到错的视图反而抢走焦点。
    @MainActor
    static func nearestTableView(above probe: NSView) -> NSTableView? {
        var ancestor = probe.superview
        while let current = ancestor {
            if let table = firstTableView(in: current) { return table }
            ancestor = current.superview
        }
        return nil
    }

    @MainActor
    static func firstTableView(in root: NSView) -> NSTableView? {
        for subview in root.subviews {
            if let table = subview as? NSTableView { return table }
            if let table = firstTableView(in: subview) { return table }
        }
        return nil
    }

    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        var lastSelectedWorkplaceID: UUID?

        init(lastSelectedWorkplaceID: UUID?) {
            self.lastSelectedWorkplaceID = lastSelectedWorkplaceID
        }
    }
}
