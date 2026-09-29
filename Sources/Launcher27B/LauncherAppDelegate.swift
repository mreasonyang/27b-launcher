import AppKit

/// Closing the studio hides its UI; downloads and service monitoring keep running.
@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    var reopenStudio: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenStudio?() }
        return true
    }
}
