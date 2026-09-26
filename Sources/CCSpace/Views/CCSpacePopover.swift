import AppKit
import SwiftUI


/// 与系统 `.popover` 同形的自管理 NSPopover 呈现。
///
/// 为什么不用 SwiftUI `.popover`:实测(macOS 26,彩虹渐变上像素级对比)SwiftUI 弹窗
/// 底层自带一层近不透明的背景,`presentationBackground(.clear)`、材质、清视图层级
/// 均无法穿透,透明度明显低于原生 NSPopover 的毛玻璃 chrome;而 `ccspaceQuickHelp`
/// 与本呈现共用同一原生 chrome,视觉完全一致。
///
/// 行为对齐系统 `.popover`:
/// - `transient`:点击弹窗外自动关闭;
/// - 每次呈现都是全新内容视图(@State 随关闭重置,与 SwiftUI presentation 语义一致),
///   关闭即释放,内容里的 `onAppear`/`onDisappear` 照常触发;
/// - 尺寸经 `sizingOptions = [.preferredContentSize]` 跟随内容自适应;
/// - 内容里可取 `\.ccspacePopoverDismiss` 环境入口,在 pick 类回调中**同步直关**弹窗
///   (见该环境键注释),不依赖 binding 回写链路。
extension View {
    func ccspacePopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(CCSpacePopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, build: content))
    }
}

/// 弹窗内容的同步关闭入口。pick 类回调(切换分支/选比较分支等)必须先关面板再派发
/// 宿主动作,而经 binding 的关闭要跨窗口走「@State 写入 → SwiftUI 下一轮事务 →
/// updateNSView → performClose」:它与派发动作的 @Published 写入同帧竞争(写入被
/// 推迟时 performClose 根本不会被调用),且 performClose 在展示/关闭动画期间会被
/// AppKit 静默忽略——两条路都间歇性导致面板关不掉、停在置灰旧状态。
/// 环境注入的入口在 AnchorView 上直调 `close()`,当帧同步完成,无中间态。
private struct CCSpacePopoverDismissKey: EnvironmentKey {
    static let defaultValue = CCSpacePopoverDismissAction(handler: {})
}

extension EnvironmentValues {
    /// 当前 ccspacePopover 弹窗的同步关闭入口;非弹窗内容层级取到的是空实现。
    var ccspacePopoverDismiss: CCSpacePopoverDismissAction {
        get { self[CCSpacePopoverDismissKey.self] }
        set { self[CCSpacePopoverDismissKey.self] = newValue }
    }
}

/// 同步关闭动作:仅主线程调用(全部调用点都在 UI 事件回调链路上),
/// 闭包持锚点视图弱引用,故标 @unchecked Sendable 满足环境值要求。
struct CCSpacePopoverDismissAction: @unchecked Sendable {
    let handler: () -> Void

    func callAsFunction() {
        handler()
    }
}

private struct CCSpacePopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @ViewBuilder let build: () -> PopoverContent

    func body(content: Content) -> some View {
        content.background(
            CCSpacePopoverAnchor(isPresented: $isPresented, arrowEdge: arrowEdge, build: build)
        )
    }
}

private struct CCSpacePopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @ViewBuilder let build: () -> Content

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onDismiss = { isPresented = false }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.onDismiss = { isPresented = false }
        view.apply(isPresented: isPresented, arrowEdge: arrowEdge, build: build)
    }

    /// 锚点 NSView:承载 popover 并跟随宿主 bounds 定位。
    final class AnchorView: NSView, NSPopoverDelegate {
        var onDismiss: (() -> Void)?
        private var popover: NSPopover?
        /// 呈现请求代际号:每次 apply 递增。延迟一帧的重试只有仍是最新请求、
        /// 且弹窗状态仍为展示中才真正 show,避免"快速开→关"时旧回调弹出
        /// 与 binding 失同步的孤儿弹窗。
        private var showRequestID = 0
        private var isPresentationRequested = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 宿主视图离开窗口(如切换工作区销毁行视图)时关闭弹窗,
            // 避免锚在已销毁视图上的弹窗悬空残留;与 SwiftUI .popover 的语义一致。
            if window == nil {
                dismissPopover()
            }
        }

        func apply(isPresented: Bool, arrowEdge: Edge, build: @escaping () -> Content) {

            // 代际号只在"请求呈现"的跳变时推进。此前每次 apply 都 +1,而父视图
            // 每次渲染都会调用 apply;若首次呈现走了"等一帧"的兜底分支,中途只要
            // 发生一次渲染(hover / 轮询刷新)请求号就被推进,这次呈现会被静默丢弃。
            if isPresented, isPresentationRequested == false {
                showRequestID += 1
            }
            let requestID = showRequestID
            isPresentationRequested = isPresented
            if isPresented {
                // 锚点尚未进窗口时等一帧再试,兜底 SwiftUI 首次布局时序。
                guard window != nil else {
                    DispatchQueue.main.async { [weak self] in
                        // 代际号已推进(如随后立刻关闭)或已不再是本次请求:放弃呈现。
                        guard let self,
                              self.showRequestID == requestID,
                              self.isPresentationRequested,
                              self.window != nil else { return }
                        self.show(arrowEdge: arrowEdge, build: build)
                    }
                    return
                }
                show(arrowEdge: arrowEdge, build: build)
            } else {
                dismissPopover()
            }
        }

        /// 同步直关弹窗:`close()` 无条件执行,跟踪引用与 binding 当帧收口,
        /// 不留"关闭中"的中间态。收口顺序:先弃跟踪(迟到的 popoverDidClose
        /// 因身份不匹配被守卫忽略),再 close(),最后同步 binding。
        func dismissPopover() {
            guard let popover else { return }
            self.popover = nil
            popover.close()
            onDismiss?()
        }

        private func show(arrowEdge: Edge, build: () -> Content) {
            if let popover, popover.isShown {
                // 呈现期间依赖变化(如远端分支加载完成):只更新内容,不重建弹窗。
                (popover.contentViewController as? NSHostingController<AnyView>)?.rootView = injectedRootView(build)
                return
            }
            // 上一任弹窗若已不在展示中(关闭动画尾窗):弃跟踪后另起新弹窗;
            // 旧弹窗晚到的 delegate 回调因身份不再匹配而被守卫拦截。
            popover = nil

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let controller = NSHostingController(rootView: injectedRootView(build))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            popover.show(relativeTo: bounds, of: self, preferredEdge: preferredEdge(for: arrowEdge))
            self.popover = popover
        }

        /// 内容统一包一层注入同步关闭入口。NSHostingController 的 rootView 类型固定,
        /// 经 AnyView 承载注入包装;弹窗内容小(定宽定高),AnyView 重建开销可忽略。
        private func injectedRootView(_ build: () -> Content) -> AnyView {
            AnyView(
                build().environment(
                    \.ccspacePopoverDismiss,
                    CCSpacePopoverDismissAction(handler: { [weak self] in self?.dismissPopover() })
                )
            )
        }

        /// SwiftUI arrowEdge 描述箭头所在边:箭头在顶边 → 弹窗向下方展开。
        private func preferredEdge(for edge: Edge) -> NSRectEdge {
            switch edge {
            case .top: .maxY
            case .bottom: .minY
            case .leading: .maxX
            case .trailing: .minX
            }
        }

        func popoverWillClose(_ notification: Notification) {
            // 关闭开始(动画前)就收口跟踪与 binding:didClose 要等动画结束才回调,
            // 这段尾窗内弹窗仍 isShown,show() 会误入"只更新内容"分支,
            // 把尾窗内用户的重开请求砸在正在消失的旧弹窗上(点击被吞)。
            // 提前弃跟踪后,尾窗内重开会直接另起新弹窗。
            guard let closingPopover = notification.object as? NSPopover,
                  closingPopover === popover else { return }
            popover = nil
            onDismiss?()
        }

        func popoverDidClose(_ notification: Notification) {
            // 兼兜底:正常路径已在 willClose 收口,此处只为不经 willClose 的关闭
            // 路径保底。身份守卫拦截一切旧弹窗迟到的回调——旧弹窗关闭动画期间
            // 用户重开时,show() 会另起新弹窗;迟到回调若照单全收,会把新弹窗
            // 的跟踪清成 nil、binding 砸回 false,新弹窗从此失联。
            guard let closedPopover = notification.object as? NSPopover,
                  closedPopover === popover else { return }
            // 用户点击外部导致的关闭:丢弃弹窗(内容视图随之销毁,onDisappear 触发)
            // 并同步回 Binding,与 SwiftUI presentation 的双向语义一致。
            popover = nil
            onDismiss?()
        }
    }
}
