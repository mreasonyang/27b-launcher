import AppKit
import SwiftUI

/// Reports the dashboard content's natural height up through the enclosing
/// `ScrollView` to ``WindowContentFitting``.
struct DashboardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Holds the hosting window so content can resize it.
///
/// A reference box rather than `@State var window: NSWindow?`: assigning the same
/// window on every `updateNSView` would invalidate the view and spin.
@MainActor
final class HostingWindowBox {
    weak var window: NSWindow?
}

/// Reports the hosting window as soon as the view is attached to it.
///
/// `updateNSView` is not reliably called, and `makeNSView` runs before the view has
/// a window, so neither can be used to learn it — `viewDidMoveToWindow` can.
private final class WindowCapturingView: NSView {
    var onWindowChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct HostingWindowReader: NSViewRepresentable {
    let box: HostingWindowBox

    func makeNSView(context: Context) -> WindowCapturingView {
        let view = WindowCapturingView(frame: .zero)
        view.onWindowChange = { [box] window in box.window = window }
        return view
    }

    func updateNSView(_ view: WindowCapturingView, context: Context) {
        view.onWindowChange = { [box] window in box.window = window }
    }
}

extension View {
    /// Marks a view as the dashboard content whose height the window should fit.
    func reportingDashboardContentHeight() -> some View {
        background(
            GeometryReader { inner in
                Color.clear.preference(
                    key: DashboardContentHeightKey.self,
                    value: inner.size.height
                )
            }
        )
    }

    /// Sizes the hosting window to the dashboard content instead of a fixed default.
    ///
    /// Apply to the `ScrollView`; the enclosed content must call
    /// ``reportingDashboardContentHeight()``.
    func fittingWindowToContent() -> some View {
        modifier(WindowContentFitting())
    }
}

/// Fits the window when the dashboard needs more room, and reclaims that room
/// when transient notices disappear.
///
/// `ScrollView` reports no intrinsic height, so `.windowResizability(.contentSize)`
/// cannot size the window from its content, and a hard-coded `defaultSize` has to
/// be kept in step with every state the dashboard can show — which this project
/// repeatedly failed to do (597 → 650 → 760, each time only after a user noticed
/// the scrolling). Instead the content and the viewport are both measured and the
/// window grows by exactly the shortfall, so new content adapts on its own.
///
/// The first measurement also fits a restored window, which can retain the height
/// of a notice from an earlier launch. A manual resize opts out for the lifetime
/// of this dashboard; subsequent shrinkage only reclaims heights set here.
struct WindowContentFitting: ViewModifier {
    @State private var box = HostingWindowBox()
    @State private var lastContentHeight: CGFloat?
    @State private var automaticallyFittedHeight: CGFloat?
    @State private var manuallyResized = false

    /// The window height that would exactly contain `contentHeight`, given the
    /// chrome measured from the live window. Shrinking requires explicit
    /// ownership of the current height; a manual window size is preserved.
    ///
    /// Absolute rather than incremental on purpose: reacting only to *content*
    /// changes left the window stranded one step short, because growing the window
    /// changes the viewport but not the content, so no further change was reported.
    nonisolated static func targetHeight(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        windowHeight: CGFloat,
        room: CGFloat,
        allowShrink: Bool = false,
        minimumViewportHeight: CGFloat = LauncherTheme.windowMinimumHeight
    ) -> CGFloat? {
        guard contentHeight > 0, viewportHeight > 0 else { return nil }
        let chrome = max(0, windowHeight - viewportHeight)
        let wanted = min(max(contentHeight, minimumViewportHeight) + chrome, room)
        if wanted > windowHeight + 1 { return wanted }
        return allowShrink && wanted < windowHeight - 1 ? wanted : nil
    }

    func body(content: Content) -> some View {
        GeometryReader { viewport in
            content
                .background(HostingWindowReader(box: box))
                .onPreferenceChange(DashboardContentHeightKey.self) { contentHeight in
                    fit(contentHeight: contentHeight)
                }
                // Growing the window changes the viewport but not the content, so
                // the preference alone would fire once and stop short. Converge on
                // the viewport too.
                .onChange(of: viewport.size.height) { _, _ in
                    fit(contentHeight: lastContentHeight ?? 0)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { notification in
                    guard let window = notification.object as? NSWindow, window === box.window else { return }
                    manuallyResized = true
                    automaticallyFittedHeight = nil
                }
                // The measurements can arrive before the hosting window is attached
                // (the reader's `view.window` is still nil), and the content height
                // then never changes again — which silently skipped every resize.
                // Wait for the window, then fit once.
                .task {
                    for _ in 0..<40 where box.window == nil {
                        try? await Task.sleep(for: .milliseconds(25))
                        guard !Task.isCancelled else { return }
                    }
                    guard !Task.isCancelled else { return }
                    fit(contentHeight: lastContentHeight ?? 0)
                }
        }
    }

    @MainActor
    private func fit(contentHeight: CGFloat) {
        lastContentHeight = contentHeight
        // Opt-in local diagnostics for checking the actual installed window.
        if ProcessInfo.processInfo.environment["LAUNCHER27B_LAYOUT_TRACE"] == "1", let window = box.window {
            let trace = "layout content=\(contentHeight) frame=\(window.frame) layout=\(window.contentLayoutRect) zoomed=\(window.isZoomed) manual=\(manuallyResized) auto=\(String(describing: automaticallyFittedHeight))\n"
            FileHandle.standardError.write(Data(trace.utf8))
        }
        guard let window = box.window, !manuallyResized, !window.inLiveResize,
              !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        // The SwiftUI viewport can still describe the frame before setFrame().
        // Read AppKit's current content area to avoid adding stale differences
        // to the title-bar height during consecutive layout passes.
        let currentViewportHeight = window.contentLayoutRect.height
        let room = window.screen?.visibleFrame.height ?? window.frame.height
        guard let target = Self.targetHeight(
            contentHeight: contentHeight,
            viewportHeight: currentViewportHeight,
            windowHeight: window.frame.height,
            room: room,
            allowShrink: automaticallyFittedHeight.map { abs($0 - window.frame.height) < 1 } ?? true
        ) else { return }

        var frame = window.frame
        frame.origin.y -= target - frame.height  // keep the top edge in place
        frame.size.height = target
        window.setFrame(frame, display: true, animate: false)
        automaticallyFittedHeight = window.frame.height
    }
}
