import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func ccspaceQuickHelp(_ text: String?) -> some View {
        if let text, text.isEmpty == false {
            modifier(CCSpaceQuickHelpModifier(text: text))
        } else {
            self
        }
    }
}

private struct CCSpaceQuickHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .overlay {
                CCSpaceQuickHelpBridge(text: text)
            }
            .accessibilityHint(text)
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
        nsView.closePopover()
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
