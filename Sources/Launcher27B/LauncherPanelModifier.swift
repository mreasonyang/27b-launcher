import SwiftUI

struct LauncherPanelModifier: ViewModifier {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast
    var padding: CGFloat = LauncherTheme.panelPadding

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background {
                if highContrast {
                    RoundedRectangle(cornerRadius: LauncherTheme.panelRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: LauncherTheme.panelRadius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LauncherTheme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LauncherTheme.panelRadius, style: .continuous)
                    .strokeBorder(
                        highContrast
                            ? Color(nsColor: .separatorColor)
                            : Color.primary.opacity(0.07),
                        lineWidth: highContrast ? 1.5 : 0.75
                    )
            }
            .shadow(
                color: highContrast ? .clear : Color.black.opacity(0.03),
                radius: 8,
                x: 0,
                y: 2
            )
    }

    private var highContrast: Bool {
        systemColorSchemeContrast == .increased || preferences.accessibilityModeEnabled
    }
}

extension View {
    func launcherPanel(padding: CGFloat = LauncherTheme.panelPadding) -> some View {
        modifier(LauncherPanelModifier(padding: padding))
    }
}
