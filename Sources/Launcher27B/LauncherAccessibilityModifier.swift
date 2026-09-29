import SwiftUI

struct LauncherAccessibilityModifier: ViewModifier {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if reduceMotion || preferences.accessibilityModeEnabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
