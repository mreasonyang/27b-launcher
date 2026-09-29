import Testing
import SwiftUI
import AppKit
@testable import Launcher27B

@Suite
struct LauncherWindowTests {
    @Test
    func desktopWindowHasAUsableResizableCanvas() {
        #expect(LauncherTheme.windowMinimumWidth >= 600)
        #expect(LauncherTheme.windowIdealWidth > LauncherTheme.windowMinimumWidth)
        #expect(LauncherTheme.windowMinimumHeight >= 560)
        #expect(LauncherTheme.windowIdealHeight > LauncherTheme.windowMinimumHeight)
    }

    @Test
    @MainActor
    func launcherFittingSizeMatchesDefaultWithoutChangingMinimum() {
        let prefs = AppPreferences()
        let ctrl = ServiceController(config: .localInstallation,
            requiresInstanceLock: false, preferences: prefs)
        let view = LauncherView(controller: ctrl)
            .environment(prefs)
            .environment(\.locale, prefs.language.locale)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        print(">>> MEASURED FITTING SIZE: \(size)")
        #expect(Double(size.width) == LauncherTheme.windowIdealWidth)
        #expect(LauncherTheme.windowMinimumWidth < Double(size.width))
        #expect(Double(size.height) >= LauncherTheme.windowMinimumHeight)
    }

    /// The window is sized to exactly contain its content, computed from live
    /// measurements rather than tracked by hand — the literal had to be bumped
    /// 597 -> 650 -> 760 and still went stale.
    @Test
    func theWindowIsSizedToExactlyContainItsContent() {
        // 597 of content plus 52 of window chrome needs 649: the case that stranded
        // the window one step short when growth only followed *content* changes.
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 597, viewportHeight: 560, windowHeight: 612, room: 1050
            ) == 649
        )
        // Already tall enough: leave it alone.
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 597, viewportHeight: 597, windowHeight: 649, room: 1050
            ) == nil
        )
        // A state notice appearing grows the window by exactly that much.
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 693, viewportHeight: 597, windowHeight: 649, room: 1050
            ) == 745
        )
        // Never taller than the screen's visible area allows.
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 2000, viewportHeight: 500, windowHeight: 600, room: 900
            ) == 900
        )
        // Unmeasured values are ignored rather than resizing to nonsense.
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 0, viewportHeight: 500, windowHeight: 600, room: 900
            ) == nil
        )
        #expect(
            WindowContentFitting.targetHeight(
                contentHeight: 500, viewportHeight: 0, windowHeight: 600, room: 900
            ) == nil
        )
    }

    @Test
    func disappearingNoticeReclaimsOnlyAutomaticallyAddedHeight() {
        #expect(WindowContentFitting.targetHeight(contentHeight: 597, viewportHeight: 693,
            windowHeight: 745, room: 1050, allowShrink: true) == 649)
        #expect(WindowContentFitting.targetHeight(contentHeight: 597, viewportHeight: 800,
            windowHeight: 852, room: 1050, allowShrink: false) == nil)
        #expect(WindowContentFitting.targetHeight(contentHeight: 400, viewportHeight: 693,
            windowHeight: 745, room: 1050, allowShrink: true) == 612)
    }


    /// Raising the default size must reach an *existing* install too: AppKit has
    /// already autosaved a window frame, and SwiftUI restores it in preference to
    /// `defaultSize`, so the new default would otherwise never apply.
    @Test
    @MainActor
    func aLayoutRevisionClearsTheRememberedWindowFrameExactlyOnce() throws {
        let suite = "layout-revision-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldFrame = "530 100 860 597 0 0 1920 1050 "
        defaults.set(oldFrame, forKey: Launcher27BApp.windowFrameAutosaveKey)
        defaults.set(Launcher27BApp.layoutRevision - 1, forKey: Launcher27BApp.layoutRevisionKey)

        Launcher27BApp.applyLayoutRevisionIfNeeded(defaults: defaults)
        #expect(defaults.string(forKey: Launcher27BApp.windowFrameAutosaveKey) == nil)
        #expect(defaults.integer(forKey: Launcher27BApp.layoutRevisionKey) == Launcher27BApp.layoutRevision)

        // At the current revision the frame must survive, or the app would forget
        // the size the user chose on every single launch.
        let resized = "530 100 900 800 0 0 1920 1050 "
        defaults.set(resized, forKey: Launcher27BApp.windowFrameAutosaveKey)
        Launcher27BApp.applyLayoutRevisionIfNeeded(defaults: defaults)
        #expect(defaults.string(forKey: Launcher27BApp.windowFrameAutosaveKey) == resized)
    }
}
