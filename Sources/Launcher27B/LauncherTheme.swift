import SwiftUI

enum LauncherTheme {
    static let windowMinimumWidth: Double = 800
    static let windowIdealWidth: Double = 860
    static let windowMinimumHeight: Double = 560
    /// The window's *initial* height only — not a value that must track the layout.
    ///
    /// The dashboard content height varies with state (the unowned-server card alone
    /// is ~96 pt), and keeping a literal in step with it failed repeatedly
    /// (597 → 650 → 760, each time only after a user noticed the scrolling).
    /// `WindowContentFitting` now measures the content and grows the window by the
    /// shortfall, so this is just the size the window opens at before the first
    /// measurement lands. Growing from a smaller value is correct; growing from a
    /// larger one would waste space.
    static let windowIdealHeight: Double = 640
    static let contentMaximumWidth: Double = 860
    static let pagePadding: Double = 16
    static let sectionSpacing: Double = 12
    static let panelPadding: Double = 16
    static let panelRadius: Double = 14
    static let accent = Color.accentColor
}
