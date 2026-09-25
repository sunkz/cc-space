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
/// - 尺寸经 `sizingOptions = [.preferredContentSize]` 跟随内容自适应。
extension View {
    func ccspacePopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(CCSpacePopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, build: content))
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
                popover?.performClose(nil)
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
            } else if let popover {
                popover.performClose(nil)
            }
        }

        private func show(arrowEdge: Edge, build: () -> Content) {
            if let popover, popover.isShown {
                // 呈现期间依赖变化(如远端分支加载完成):只更新内容,不重建弹窗。
                (popover.contentViewController as? NSHostingController<Content>)?.rootView = build()
                return
            }

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let controller = NSHostingController(rootView: build())
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            popover.show(relativeTo: bounds, of: self, preferredEdge: preferredEdge(for: arrowEdge))
            self.popover = popover
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

        func popoverDidClose(_ notification: Notification) {
            // 用户点击外部或程序化关闭:丢弃弹窗(内容视图随之销毁,onDisappear 触发)
            // 并同步回 Binding,与 SwiftUI presentation 的双向语义一致。
            popover = nil
            onDismiss?()
        }
    }
}
