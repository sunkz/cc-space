import Foundation
import AppKit
import SwiftUI

/// 外观模式的工具栏循环切换呈现数据(纯逻辑,便于测试):
/// 单个按钮按 浅色 → 深色 → 跟随系统 循环,图标/文案跟随"当前持久化模式"
/// (而非生效外观——system 态下系统可能正处浅色或深色,图标须稳定表达"跟随系统")。
extension AppSettings.AppearanceMode {
    static let cycleOrder: [AppSettings.AppearanceMode] = [.light, .dark, .system]

    var nextInCycle: AppSettings.AppearanceMode {
        switch self {
        case .light: .dark
        case .dark: .system
        case .system: .light
        }
    }

    var displayName: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var toolbarSystemImage: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var toolbarButtonTitle: String {
        "外观:\(displayName),点击切换到\(nextInCycle.displayName)"
    }
}

/// 将外观模式应用到整个 App(经 NSApp.appearance,独立 Diff 窗口同样生效)。
enum AppearanceModeApplier {
    /// 外观模式对应的 NSAppearance 名称;system 返回 nil 表示跟随系统。
    static func nsAppearanceName(for mode: AppSettings.AppearanceMode) -> NSAppearance.Name? {
        switch mode {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// App 级覆盖与持久化模式是否不一致(纯逻辑,便于测试)。
    /// 覆盖为 nil 也算不一致(显式模式下覆盖缺失即未生效);system 模式期望覆盖为 nil。
    static func isOverrideOutOfSync(
        _ overrideName: NSAppearance.Name?,
        with mode: AppSettings.AppearanceMode
    ) -> Bool {
        overrideName != nsAppearanceName(for: mode)
    }

    /// 兜底:App 级覆盖与持久化模式不一致时重新应用。
    /// SwiftUI 重渲染、新开 Diff 窗口等时机可能把 NSApp.appearance 重置回 nil,
    /// 表现为"切换不生效、图标与实际外观相反";在生效外观变化通知里调用本方法自愈。
    /// apply 与期望一致时为幂等 no-op,不会循环。
    @MainActor
    static func reconcileOverride(with mode: AppSettings.AppearanceMode) {
        guard isOverrideOutOfSync(NSApp?.appearance?.name, with: mode) else { return }
        apply(mode)
    }

    @MainActor
    static func apply(_ mode: AppSettings.AppearanceMode) {
        let appearance = nsAppearanceName(for: mode).flatMap { NSAppearance(named: $0) }
        NSApp?.appearance = appearance
        // macOS 26 实测:只改 App 级覆盖时,已渲染的窗口内容可能数秒不重绘
        // (点切换后页面停在旧外观,滚动一下才刷新)。给每个已存在窗口显式设置
        // 相同 appearance,AppKit 会立即沿视图树传播生效;system 模式为 nil,
        // 窗口继续跟随系统,行为不变。新建窗口继承 App 级覆盖,无需处理。
        // 标题栏/工具栏的玻璃底座由主题框视图绘制,不随内容视图重绘,
        // 需要一并标记失效(表现为右上角按钮组背景延迟数秒才换外观)。
        for window in NSApp?.windows ?? [] {
            window.appearance = appearance
            window.contentView?.superview?.needsDisplay = true
            window.toolbar?.items.forEach { item in
                item.view?.needsDisplay = true
            }
        }
    }
}

/// 隐形观察者:借助 NSView.viewDidChangeEffectiveAppearance 感知生效外观变化
/// (本 App 切换、系统切换、外部重置 NSApp.appearance 均会回调),
/// 驱动 SwiftUI 重算外观按钮并触发覆盖自愈。
/// AppKit 未提供对应的通知名,这是官方建议的观察途径之一。
struct EffectiveAppearanceObserver: NSViewRepresentable {
    let onChange: () -> Void

    func makeNSView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObservationView, context: Context) {
        view.onChange = onChange
    }

    final class ObservationView: NSView {
        var onChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onChange?()
        }
    }
}
