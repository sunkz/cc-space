import AppKit
import SwiftUI

extension View {
    /// 悬浮提示。
    /// - Parameters:
    ///   - providesLabel: 是否同时把文案作为 `accessibilityLabel`。
    ///     仅图标按钮(没有可见文字)应传 true:此前只设了 hint 不设 label,
    ///     VoiceOver 下这些按钮是没有名字的控件。已有可见文字/已显式设 label 的
    ///     控件不要传,避免覆盖更精确的 label。
    ///   - label: 无障碍名称与悬浮文案不一致时传入(如文案尾部带配置提示),
    ///     传入即按已设置 label 处理;悬浮气泡仍用 `text`。
    ///   - hint: 无障碍提示与悬浮文案不一致时传入。
    ///
    ///   label 与 hint 相同的话只挂 label:同一串文案会被 VoiceOver
    ///   先当 label 读、再当 hint 原样重读一遍。
    ///
    ///   三分支的分流规则抽在 `CCSpaceQuickHelpResolution.resolve`(纯值,有单测矩阵)。
    @ViewBuilder
    func ccspaceQuickHelp(
        _ text: String?,
        providesLabel: Bool = false,
        label: String? = nil,
        hint: String? = nil
    ) -> some View {
        if let text, text.isEmpty == false {
            modifier(CCSpaceQuickHelpModifier(
                text: text,
                providesLabel: providesLabel,
                label: label,
                hint: hint
            ))
        } else {
            self
        }
    }
}

/// `ccspaceQuickHelp` 的 label/hint 分流结果(纯值,便于单测;语义见该方法的参数说明)。
///
/// 三分支:只挂 label(label 与 hint 相同或 hint 缺省时去重)、label+hint、只挂 hint;
/// `text` 为空表示整体跳过(label/hint 均 nil,不挂 modifier)。
struct CCSpaceQuickHelpResolution: Equatable {
    let label: String?
    let hint: String?

    static func resolve(
        text: String?,
        providesLabel: Bool = false,
        label: String? = nil,
        hint: String? = nil
    ) -> CCSpaceQuickHelpResolution {
        guard let text, text.isEmpty == false else {
            return CCSpaceQuickHelpResolution(label: nil, hint: nil)
        }
        let resolvedLabel: String? = label ?? (providesLabel ? text : nil)
        let resolvedHint = hint ?? text
        if let resolvedLabel, resolvedHint == resolvedLabel {
            // 同一串文案只进 label:再作 hint 会被 VoiceOver 原样重读一遍。
            return CCSpaceQuickHelpResolution(label: resolvedLabel, hint: nil)
        }
        return CCSpaceQuickHelpResolution(label: resolvedLabel, hint: resolvedHint)
    }
}

private struct CCSpaceQuickHelpModifier: ViewModifier {
    let text: String
    let providesLabel: Bool
    let label: String?
    let hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        // 分流只走 CCSpaceQuickHelpResolution(与单测同一份实现),这里只负责按结果挂属性。
        let resolution = CCSpaceQuickHelpResolution.resolve(
            text: text,
            providesLabel: providesLabel,
            label: label,
            hint: hint
        )
        if let resolvedLabel = resolution.label, let resolvedHint = resolution.hint {
            content
                .overlay {
                    CCSpaceQuickHelpBridge(text: text)
                }
                .accessibilityLabel(resolvedLabel)
                .accessibilityHint(resolvedHint)
        } else if let resolvedLabel = resolution.label {
            content
                .overlay {
                    CCSpaceQuickHelpBridge(text: text)
                }
                .accessibilityLabel(resolvedLabel)
        } else if let resolvedHint = resolution.hint {
            content
                .overlay {
                    CCSpaceQuickHelpBridge(text: text)
                }
                .accessibilityHint(resolvedHint)
        } else {
            // text 为空:上游 ccspaceQuickHelp 已挡,这里兜底保持原样透传。
            content
        }
    }
}

private struct CCSpaceQuickHelpBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> CCSpaceQuickHelpTrackingView {
        let view = CCSpaceQuickHelpTrackingView()
        view.update(text: text)
        return view
    }

    func updateNSView(_ nsView: CCSpaceQuickHelpTrackingView, context: Context) {
        nsView.update(text: text)
    }

    static func dismantleNSView(_ nsView: CCSpaceQuickHelpTrackingView, coordinator: ()) {
        nsView.prepareForDismantle()
    }
}

private final class CCSpaceQuickHelpTrackingView: NSView {
    private let hoverDelay = Duration.milliseconds(120)

    private var trackingArea: NSTrackingArea?
    private var pendingShowTask: Task<Void, Never>?
    private var popoverEventMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var text: String = ""

    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        return popover
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseEnteredAndExited
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        schedulePopoverShow()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        closePopover()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateNotificationObservers()
        if window == nil {
            closePopover()
            removeNotificationObservers()
        }
    }

    func update(text: String) {
        self.text = text
        if popover.isShown {
            refreshPopoverContent()
        }
    }

    func closePopover() {
        pendingShowTask?.cancel()
        pendingShowTask = nil
        removePopoverEventMonitor()

        if popover.isShown {
            popover.performClose(nil)
        }
    }

    /// SwiftUI 拆除视图时的兜底清理:三个 block 观察者依赖 viewDidMoveToWindow 的
    /// 副作用清理,dismantle 时刻视图可能已摘窗、不再触发那条路径,会一直挂到进程结束。
    /// 不放 deinit:NSView 隐式 @MainActor 而 deinit 是非隔离上下文,Swift 6 下访问有隔离风险。
    func prepareForDismantle() {
        closePopover()
        removeNotificationObservers()
    }

    private func updateNotificationObservers() {
        guard observedWindow !== window else { return }

        removeNotificationObservers()
        observedWindow = window

        guard let window else { return }

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.closePopover()
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.closePopover()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.closePopover()
                }
            }
        ]
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
        observedWindow = nil
    }

    private func schedulePopoverShow() {
        pendingShowTask?.cancel()
        let delay = self.hoverDelay

        pendingShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false, let self else { return }
            self.showPopover()
            self.pendingShowTask = nil
        }
    }

    private func showPopover() {
        guard text.isEmpty == false, window != nil, isPointerInsideTrackedBounds() else { return }

        refreshPopoverContent()

        if popover.isShown == false {
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        }
        configurePopoverWindow()
        installPopoverEventMonitor()
    }

    private func refreshPopoverContent() {
        let metrics = CCSpaceQuickHelpLayoutMetrics(text: text)
        let controller = NSHostingController(
            rootView: CCSpaceQuickHelpBubble(
                text: text,
                textWidth: metrics.textWidth
            )
        )
        let view = controller.view
        let size = metrics.popoverSize

        view.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
        popover.contentViewController = controller
        // 整体替换 contentViewController 后弹窗窗口的配置(如 ignoresMouseEvents)会随旧
        // 窗口丢失,重新配置一次;未呈现时 view.window 为 nil,调用是安全的空操作。
        configurePopoverWindow()
    }

    private func configurePopoverWindow() {
        popover.contentViewController?.view.window?.ignoresMouseEvents = true
    }

    private func installPopoverEventMonitor() {
        guard popoverEventMonitor == nil else { return }

        popoverEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .scrollWheel,
            ]
        ) { [weak self] event in
            self?.handleTrackedPointerEvent()
            return event
        }
    }

    private func removePopoverEventMonitor() {
        if let popoverEventMonitor {
            NSEvent.removeMonitor(popoverEventMonitor)
            self.popoverEventMonitor = nil
        }
    }

    private func handleTrackedPointerEvent() {
        guard popover.isShown else {
            removePopoverEventMonitor()
            return
        }

        guard isPointerInsideTrackedBounds() else {
            closePopover()
            return
        }
    }

    private func isPointerInsideTrackedBounds() -> Bool {
        guard let window else { return false }
        let pointerLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return CCSpaceQuickHelpPointerBounds(bounds: bounds).contains(pointerLocation)
    }
}

struct CCSpaceQuickHelpLayoutMetrics {
    static let maxTextWidth: CGFloat = 240
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7

    let textWidth: CGFloat
    let popoverSize: CGSize

    init(text: String) {
        let resolvedTextWidth = min(Self.maxTextWidth, Self.preferredSingleLineWidth(for: text))
        let textHeight = Self.textBoundingRect(for: text, width: resolvedTextWidth).height

        textWidth = resolvedTextWidth
        popoverSize = CGSize(
            width: ceil(resolvedTextWidth + (Self.horizontalPadding * 2)),
            height: ceil(textHeight + (Self.verticalPadding * 2))
        )
    }

    private static func preferredSingleLineWidth(for text: String) -> CGFloat {
        let lines = text.components(separatedBy: .newlines)
        let widestLine = lines
            .map { ceil(($0 as NSString).size(withAttributes: textAttributes).width) }
            .max() ?? 0
        return max(1, widestLine)
    }

    private static func textBoundingRect(for text: String, width: CGFloat) -> CGRect {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes
        )
    }

    nonisolated(unsafe) private static let textAttributes: [NSAttributedString.Key: Any] = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: NSFont.preferredFont(forTextStyle: .caption1),
            .paragraphStyle: paragraphStyle
        ]
    }()
}

struct CCSpaceQuickHelpPointerBounds {
    static let exitTolerance: CGFloat = 4

    let bounds: CGRect

    func contains(_ point: CGPoint) -> Bool {
        bounds.insetBy(dx: -Self.exitTolerance, dy: -Self.exitTolerance).contains(point)
    }
}

private struct CCSpaceQuickHelpBubble: View {
    let text: String
    let textWidth: CGFloat

    var body: some View {
        // 不画背景:透出 NSPopover 原生毛玻璃 chrome,
        // 与 ccspacePopover 呈现的弹窗共用同一套材质。
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: textWidth, alignment: .leading)
            .padding(.horizontal, CCSpaceQuickHelpLayoutMetrics.horizontalPadding)
            .padding(.vertical, CCSpaceQuickHelpLayoutMetrics.verticalPadding)
    }
}
