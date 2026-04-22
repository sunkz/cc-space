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

    func ccspaceIconActionButton() -> some View {
        buttonStyle(.plain)
            .controlSize(.small)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
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

    func ccspaceToolbarStatusIndicator() -> some View {
        controlSize(.small)
            .frame(minWidth: 30, minHeight: 28, alignment: .center)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
    }
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
    let subtitle: String
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
            return accent.opacity(0.03)
        }
        if isHovering {
            return Color.primary.opacity(0.008)
        }
        return .clear
    }

    var body: some View {
        content()
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
