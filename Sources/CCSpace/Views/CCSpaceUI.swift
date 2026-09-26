import SwiftUI

extension View {
    func ccspacePanel(
        background: Color = .clear,
        cornerRadius: CGFloat = 10,
        padding: CGFloat = 10,
        borderOpacity: Double = 0
    ) -> some View {
        modifier(
            CCSpacePanelModifier(
                background: background,
                cornerRadius: cornerRadius,
                padding: padding,
                borderOpacity: borderOpacity
            )
        )
    }

    func ccspaceInsetPanel(
        background: Color = .clear,
        cornerRadius: CGFloat = 10,
        padding: CGFloat = 6,
        borderOpacity: Double = 0
    ) -> some View {
        modifier(
            CCSpacePanelModifier(
                background: background,
                cornerRadius: cornerRadius,
                padding: padding,
                borderOpacity: borderOpacity
            )
        )
    }

    func ccspaceScreenBackground() -> some View {
        background {
            CCSpaceScreenBackground()
        }
    }

    func ccspacePrimaryActionButton() -> some View {
        buttonStyle(.borderedProminent)
            .controlSize(.small)
            .font(.footnote)
    }

    func ccspaceSecondaryActionButton() -> some View {
        buttonStyle(.bordered)
            .controlSize(.small)
            .font(.footnote)
    }

    func ccspaceCompactActionButton() -> some View {
        buttonStyle(.plain)
            .controlSize(.small)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    func ccspaceIconActionButton(large: Bool = false) -> some View {
        modifier(CCSpaceIconActionButtonModifier(large: large))
    }

    @ViewBuilder
    func ccspaceToolbarActionButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.plain)
                .controlSize(.regular)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 30, minHeight: 28)
                .contentShape(Rectangle())
        } else {
            buttonStyle(.plain)
                .controlSize(.small)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

}

/// NSMenu/AppKit 渲染场景下的空白占位图标:
/// 菜单里的 SwiftUI Button 会被转成 NSMenuItem,opacity/hidden 等修饰会被忽略,
/// 只有"真实存在但不绘制内容"的图片才能既占住图标列宽度又不显形。
enum MenuPlaceholderIcon {
    /// 默认分支星标(MR 目标分支菜单)。
    static let star: NSImage = {
        let image = NSImage(systemSymbolName: "star", accessibilityDescription: "默认分支") ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// 空白占位图:尺寸与 star 完全一致,保证菜单图标列等宽、分支名文字左右对齐;
    /// 菜单里的 SwiftUI Button 会被转成 NSMenuItem,opacity/hidden 等修饰会被忽略,
    /// 只有"真实存在但不绘制内容"的图片才能既占住图标列宽度又不显形。
    static let blank: NSImage = {
        let image = NSImage(size: star.size)
        image.isTemplate = true
        return image
    }()
}

struct CCSpaceEmptyStateCard<Actions: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

struct CCSpacePill: View {
    let title: String
    var systemImage: String?
    var tint: Color

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption)
        .fontWeight(.regular)
        .contentTransition(.numericText())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.035), in: Capsule())
        .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary.opacity(0.85))
    }
}

struct CCSpaceSectionTitle: View {
    let title: String
    var subtitle: String = ""
    var titleFont: Font = .footnote
    var titleWeight: Font.Weight = .regular
    var titleColor: Color = .secondary
    var subtitleColor: Color = .secondary.opacity(0.7)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(titleFont)
                .fontWeight(titleWeight)
                .foregroundStyle(titleColor)
            if subtitle.isEmpty == false {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
            }
        }
    }
}

struct CCSpaceInteractiveCard<Content: View>: View {
    let selected: Bool
    var accent: Color = .accentColor
    var cornerRadius: CGFloat = 10
    var padding: CGFloat = 8
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    private var backgroundColor: Color {
        if selected {
            return accent.opacity(0.05)
        }
        if isHovering {
            return Color.primary.opacity(0.04)
        }
        return .clear
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(.snappy(duration: 0.18), value: isHovering)
            .animation(.snappy(duration: 0.18), value: selected)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct CCSpacePanelModifier: ViewModifier {
    let background: Color
    let cornerRadius: CGFloat
    let padding: CGFloat
    let borderOpacity: Double

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(borderOpacity))
            }
    }
}

private struct CCSpaceScreenBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

private struct CCSpaceIconActionButtonModifier: ViewModifier {
    /// 尺寸档:设置页仓库行的操作按钮用 `large`(28pt 框 + 一号图标),
    /// 工作区仓库行等保持 compact 原规格,不连带变化。
    var large: Bool = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .controlSize(.small)
            .font(large ? .body.weight(.medium) : .footnote.weight(.medium))
            .foregroundStyle(isHovering ? Color.primary : .secondary)
            .frame(width: large ? 28 : 24, height: large ? 28 : 24)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct CCSpaceShimmerPill: View {
    @State private var shimmerPhase = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(shimmerPhase ? 0.06 : 0.03))
            .frame(width: 48, height: 18)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: shimmerPhase
            )
            .onAppear {
                shimmerPhase = true
            }
    }
}
