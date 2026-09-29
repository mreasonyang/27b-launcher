import SwiftUI

struct LauncherBackdrop: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if !preferences.accessibilityModeEnabled {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.03),
                        Color.clear,
                        Color.primary.opacity(0.015)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
