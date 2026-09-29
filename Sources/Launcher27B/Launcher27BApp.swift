import SwiftUI

@main
@MainActor
struct Launcher27BApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate
    @State private var preferences: AppPreferences
    @State private var controller: ServiceController

    init() {
        Self.applyLayoutRevisionIfNeeded()
        let preferences = AppPreferences()
        let controller = ServiceController(
            config: .localInstallation,
            preferences: preferences
        )
        // Take the process-wide instance lock *before* monitoring starts: a
        // second launcher must never touch `bonsaiServerPID`/the run-intent flag
        // owned by the first one. The lock is held for the process lifetime and
        // released on termination.
        controller.acquireSingleInstanceLock()
        controller.startMonitoring()
        _preferences = State(initialValue: preferences)
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        Window("27B Launcher", id: "studio") {
            LauncherView(controller: controller, appDelegate: appDelegate)
                .modifier(LauncherAccessibilityModifier())
                .environment(preferences)
                .environment(\.locale, preferences.language.locale)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
        .defaultPosition(.center)
        .defaultSize(
            width: LauncherTheme.windowIdealWidth,
            height: LauncherTheme.windowIdealHeight
        )
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { QuickStartCommands(controller: controller, preferences: preferences) }

        Settings {
            DisplayPreferencesPanel(controller: controller)
                .modifier(LauncherAccessibilityModifier())
                .environment(preferences)
                .environment(\.locale, preferences.language.locale)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }

    /// Bump when `LauncherTheme.windowIdealHeight`/`Width` changes meaningfully.
    ///
    /// The window frame is autosaved by AppKit, so raising the *default* size does
    /// nothing for an existing install: SwiftUI restores the remembered frame and
    /// the taller content then scrolls. Clearing the saved frame once lets the new
    /// default apply, while resizes the user makes afterwards are still remembered
    /// until the next bump.
    // Discard frames left oversized by the previous growth-only fitter once.
    static let layoutRevision = 3
    static let layoutRevisionKey = "launcherLayoutRevision"
    static let windowFrameAutosaveKey = "NSWindow Frame studio"

    static func applyLayoutRevisionIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: layoutRevisionKey) != layoutRevision else { return }
        defaults.removeObject(forKey: windowFrameAutosaveKey)
        defaults.set(layoutRevision, forKey: layoutRevisionKey)
    }
}
