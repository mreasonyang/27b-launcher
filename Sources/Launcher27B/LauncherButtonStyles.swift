import SwiftUI

// MARK: - Studio Primary Button Style
struct StudioPrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var glowColor: Color = LauncherTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        StudioPrimaryButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            glowColor: glowColor
        )
    }
}

private struct StudioPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let glowColor: Color

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    glowColor.opacity(isHovered ? 1.0 : 0.92),
                                    glowColor.opacity(isHovered ? 0.90 : 0.82)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.40 : 0.22),
                                    Color.white.opacity(isHovered ? 0.14 : 0.04)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(
                color: glowColor.opacity(isEnabled && isHovered ? 0.35 : 0.12),
                radius: isHovered ? 5 : 2,
                y: isHovered ? 2 : 1
            )
            .scaleEffect(
                configuration.isPressed ? 0.97 : (isHovered && isEnabled ? 1.02 : 1.0)
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else {
                    isHovered = false
                    return
                }
                isHovered = hovering
            }
    }
}

// MARK: - Studio Secondary Button Style
struct StudioSecondaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var hoverTint: Color = .primary
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StudioSecondaryButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverTint: hoverTint,
            isDestructive: isDestructive
        )
    }
}

private struct StudioSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let hoverTint: Color
    let isDestructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(effectiveForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(effectiveBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(effectiveBorder, lineWidth: 0.75)
            }
            .scaleEffect(
                configuration.isPressed ? 0.97 : (isHovered && isEnabled ? 1.015 : 1.0)
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else {
                    isHovered = false
                    return
                }
                isHovered = hovering
            }
    }

    private var effectiveForeground: Color {
        guard isEnabled else { return .secondary }
        if isHovered {
            return isDestructive ? .red : (hoverTint == .primary ? .primary : hoverTint)
        }
        return .primary
    }

    private var effectiveBackground: Color {
        guard isEnabled else { return Color.primary.opacity(0.02) }
        if isHovered {
            return isDestructive ? Color.red.opacity(0.09) : Color.primary.opacity(0.08)
        }
        return Color.primary.opacity(0.04)
    }

    private var effectiveBorder: Color {
        guard isEnabled else { return Color.primary.opacity(0.05) }
        if isHovered {
            return isDestructive ? Color.red.opacity(0.3) : Color.primary.opacity(0.18)
        }
        return Color.primary.opacity(0.09)
    }
}

// MARK: - Studio Copy Pill Button Style
struct StudioCopyPillButtonStyle: ButtonStyle {
    var activeColor: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StudioCopyPillButtonBody(configuration: configuration, activeColor: activeColor)
    }
}

private struct StudioCopyPillButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let activeColor: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(isHovered ? activeColor.opacity(0.12) : Color.clear)
            }
            .overlay {
                Capsule()
                    .strokeBorder(isHovered ? activeColor.opacity(0.22) : Color.clear, lineWidth: 0.5)
            }
            .scaleEffect(
                configuration.isPressed ? 0.95 : (isHovered && isEnabled ? 1.04 : 1.0)
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Convenience Extensions
extension ButtonStyle where Self == StudioPrimaryButtonStyle {
    static var studioPrimary: StudioPrimaryButtonStyle {
        StudioPrimaryButtonStyle()
    }
    static func studioPrimary(tint: Color = LauncherTheme.accent) -> StudioPrimaryButtonStyle {
        StudioPrimaryButtonStyle(glowColor: tint)
    }
}

extension ButtonStyle where Self == StudioSecondaryButtonStyle {
    static var studioSecondary: StudioSecondaryButtonStyle {
        StudioSecondaryButtonStyle()
    }
    static func studioSecondary(tint: Color = .primary, destructive: Bool = false) -> StudioSecondaryButtonStyle {
        StudioSecondaryButtonStyle(hoverTint: tint, isDestructive: destructive)
    }
}

extension ButtonStyle where Self == StudioCopyPillButtonStyle {
    static var studioCopyPill: StudioCopyPillButtonStyle {
        StudioCopyPillButtonStyle()
    }
    static func studioCopyPill(activeColor: Color = .accentColor) -> StudioCopyPillButtonStyle {
        StudioCopyPillButtonStyle(activeColor: activeColor)
    }
}
