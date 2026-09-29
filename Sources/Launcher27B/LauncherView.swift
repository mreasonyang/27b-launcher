import SwiftUI

struct LauncherView: View {
    @Bindable var controller: ServiceController
    var appDelegate: LauncherAppDelegate? = nil
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if controller.quickStartRoute == .setup {
                StudioInstallerOverlay(controller: controller)
            } else if controller.quickStartRoute == .deferred {
                DeferredSetupView(controller: controller)
            } else {
                StudioDashboardView(controller: controller)
            }
        }
        .frame(
            minWidth: LauncherTheme.windowMinimumWidth,
            idealWidth: LauncherTheme.windowIdealWidth,
            minHeight: LauncherTheme.windowMinimumHeight,
            idealHeight: LauncherTheme.windowIdealHeight
        )
        .background(LauncherBackdrop())
        .navigationTitle("27B Launcher")
        .navigationSubtitle("Bonsai 2 · 27B")
        .onAppear {
            appDelegate?.reopenStudio = { openWindow(id: "studio") }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(toolbarStatusColor)
                        .frame(width: 7, height: 7)
                    Text(preferences.localized(controller.status.title))
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(toolbarStatusColor.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(toolbarStatusColor.opacity(0.25), lineWidth: 0.5))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(preferences.localizedFormat(
                    "服务状态：%@",
                    preferences.localized(controller.status.title)
                ))
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if controller.quickStartRoute == .setup || controller.installationStatus != .ready {
                    Menu {
                        ForEach(AppLanguage.allCases) { language in
                            Button(language.nativeName) { preferences.language = language }
                        }
                    } label: {
                        Label(preferences.localized("语言"), systemImage: "globe")
                    }
                    .accessibilityLabel(preferences.localized("语言"))
                    .help(preferences.localized("语言"))
                }
                Button(action: controller.revealLogs) {
                    Label(preferences.localized("查看日志"), systemImage: "doc.text.magnifyingglass")
                }
                .help(preferences.localized("查看日志"))

                SettingsLink {
                    Label(preferences.localized("设置"), systemImage: "gearshape")
                }
                .help(preferences.localized("显示与语言"))
            }
        }
        // Driven by the controller's retained error rather than by a transient
        // view-local flag: the app keeps running with no window open, so an
        // alert the user never dismissed must still be waiting when the window
        // is reopened.
        .alert("27B Launcher", isPresented: Binding(
            get: { controller.hasPresentedError },
            set: { isPresented in
                if !isPresented { controller.acknowledgePresentedError() }
            }
        )) {
            Button(preferences.localized("好"), role: .cancel) {
                controller.acknowledgePresentedError()
            }
        } message: {
            Text(
                controller.presentedError
                    ?? controller.latestError
                    ?? preferences.localized("发生未知错误")
            )
        }
    }

    private var toolbarStatusColor: Color {
        switch controller.status {
        case .running: .green
        case .starting, .restarting, .checking: .orange
        case .external: .blue
        case .stopped, .stopping: .secondary
        }
    }
}

// MARK: - Secondary-instance notice

/// Explains why every control in this window is inert when a second launcher
/// already owns the process-wide instance lock.
struct LauncherInstanceNotice: View {
    let ownerPID: pid_t
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(preferences.localized("另一个启动器实例正在运行"))
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(preferences.localizedFormat(
                    "进程 PID %lld 已经在管理模型服务。为避免两个启动器争用同一个服务，此窗口中的控制已停用。",
                    Int64(ownerPID)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Testable presentation logic

/// What the single hero button does in the current state.
enum StudioPrimaryAction: Equatable {
    case start
    case openChat
    case copyAPIAddress
    case adoptUnownedServer
    case busy
}

/// Whether the launcher is silently retrying a failed start, or has given up.
enum SupervisionNotice: Equatable {
    case none
    case retrying(failures: Int, retryAfterSeconds: Int)
    case paused(failures: Int)
    /// Supervision gave up because the server kept crashing *after* having been
    /// observed healthy.
    ///
    /// `failures` is carried for completeness but is not the story: a slow crash
    /// loop pauses with `consecutiveFailures == 1`, so a notice built from the
    /// counter alone understates the problem and never mentions the crashes.
    case pausedByCrashLoop(crashes: Int, failures: Int)
    /// Supervision gave up on the start-attempt budget while crashes were still
    /// inside the crash-rate window.
    ///
    /// The pause reason here is `.repeatedStartFailures(count:)`, which carries
    /// no crash count; without this case the crashes that are already known
    /// (`ServiceController/crashesInCrashWindow`) were dropped from the message
    /// even though they are real evidence the counter cannot express.
    case pausedAfterCrashes(failures: Int, crashes: Int)

    /// The localization key — specifiers included — this notice renders.
    ///
    /// The view formats through this key rather than hard-coding a message per
    /// case, so the reason the pause happened is what picks the sentence. The
    /// crash-loop pause in particular must not fall back to the failure-count
    /// wording: it arrives with `consecutiveFailures == 1`.
    var messageKey: String? {
        switch self {
        case .none:
            nil
        case .retrying:
            "启动已失败 %lld 次，正在自动重试（约 %lld 秒后）。"
        case .paused:
            "已连续失败 %lld 次，自动重启已暂停；请点击“启动模型”手动重试，并查看日志排查原因。"
        case .pausedByCrashLoop:
            "模型在 %lld 分钟内崩溃 %lld 次，自动重启已暂停；请点击“启动模型”手动重试，并查看日志排查原因。"
        case .pausedAfterCrashes:
            "已连续失败 %lld 次，期间还崩溃 %lld 次；自动重启已暂停，请点击“启动模型”手动重试，并查看日志排查原因。"
        }
    }
}

/// What the installer must not present as a plain missing-model situation.


/// The single preflight banner the installer shows before a multi-gigabyte
/// download starts.
enum HardwarePreflightNotice: Equatable {
    case none
    case warning(String)
    case blocker(String)
}

/// Pure state-to-presentation mapping for the launcher's wiring.
///
/// Kept free of SwiftUI and of `AppPreferences` so the decisions that close the
/// broken states (LAN chat hidden, unowned server actionable, retry budget
/// visible, install refused before downloading) can be asserted in tests.
enum StudioPresentation {
    /// The hero button must never offer the bundled chat page when the launcher
    /// started the server with `--no-webui`; in that mode it offers the API
    /// address instead so there is still a working way to reach the model.
    ///
    /// Adoption is likewise only offered when it can actually succeed: a listener
    /// identified through the port is not the launcher's binary, so
    /// `discoverRunningServer()` finds nothing for it and the action returned
    /// `false` without a spinner, an alert or a state change — while replacing
    /// Start/Open Chat as the most prominent control in the window.
    static func primaryAction(
        status: ServiceStatus,
        isBusy: Bool,
        hasUnownedServer: Bool,
        unownedServerIsForeign: Bool,
        canOpenChat: Bool,
        chatOptionsAreUnknown: Bool
    ) -> StudioPrimaryAction {
        if isBusy { return .busy }
        if hasUnownedServer, !unownedServerIsForeign { return .adoptUnownedServer }
        switch status {
        case .running, .external:
            // A server this process never started has no recorded launch
            // options, so the preference is only a guess and a `--no-webui`
            // server may be the one answering. The API address works either way.
            return canOpenChat && !chatOptionsAreUnknown ? .openChat : .copyAPIAddress
        case .checking, .stopped, .starting, .stopping, .restarting:
            return .start
        }
    }

    static func isPrimaryActionEnabled(
        _ action: StudioPrimaryAction,
        canStart: Bool,
        isBusy: Bool
    ) -> Bool {
        switch action {
        case .busy:
            false
        case .start:
            canStart
        case .openChat, .copyAPIAddress, .adoptUnownedServer:
            !isBusy
        }
    }

    /// `AutoRestartSupervision` pauses at its failure budget until the user
    /// starts the service by hand; both the retrying and the paused state were
    /// otherwise hidden from the current storage status.
    ///
    /// The pause has two causes and they must not be conflated: five consecutive
    /// failed *starts*, or a crash loop (crashes inside the crash-rate window).
    /// The counted failures alone understate the crash-loop pause, which arrives
    /// with `consecutiveFailures == 1`.
    ///
    /// `crashesInCrashWindow` is the crash evidence for the pause reason that
    /// does *not* carry it: `.repeatedStartFailures` is what a budget-exhausted
    /// pause looks like even when crashes happened on the way there, and those
    /// crashes are the only thing that explains the shape of the failure.
    static func supervisionNotice(
        consecutiveFailures: Int,
        isAutoRestartWanted: Bool,
        pauseReason: SupervisionPauseReason? = nil,
        crashesInCrashWindow: Int = 0
    ) -> SupervisionNotice {
        guard consecutiveFailures > 0 else { return .none }
        if case let .crashLoop(crashesInWindow) = pauseReason {
            return .pausedByCrashLoop(
                crashes: crashesInWindow,
                failures: consecutiveFailures
            )
        }
        guard isAutoRestartWanted,
              consecutiveFailures < AutoRestartSupervision.maximumConsecutiveFailures
        else {
            return crashesInCrashWindow > 0
                ? .pausedAfterCrashes(
                    failures: consecutiveFailures,
                    crashes: crashesInCrashWindow
                )
                : .paused(failures: consecutiveFailures)
        }
        let backoff = AutoRestartSupervision.backoff(forFailureCount: consecutiveFailures)
        return .retrying(
            failures: consecutiveFailures,
            retryAfterSeconds: Int(backoff.components.seconds)
        )
    }

    /// Whether the installer must lead with a multi-gigabyte download, or with
    /// the copy of the models that is already on disk.


    static func hardwarePreflight(
        assessment: HardwareAssessment,
        message: String?
    ) -> HardwarePreflightNotice {
        guard let message else { return .none }
        switch assessment {
        case .satisfied:
            return .none
        case .warning:
            return .warning(message)
        case .unsatisfied:
            return .blocker(message)
        }
    }

    /// The base URL other devices and API clients should use, without the
    /// bundled chat page.
    static func apiAddress(for config: LauncherConfig) -> String {
        config.chatURL.appending(path: "v1").absoluteString
    }

    /// Components whose on-disk bytes failed verification, in catalog order.
    static func componentsNeedingRepair(
        in results: [InstallationComponent: ArtifactVerification]
    ) -> [InstallationComponent] {
        InstallationComponent.allCases.filter { results[$0]?.needsRepair == true }
    }
}

extension ArtifactVerification {
    /// True when the artifact on disk is unusable and must be replaced.
    ///
    /// `.notDigestVerifiable` is a *pass*: runtime archives are validated
    /// structurally (release marker, executables) rather than by digest.
    var needsRepair: Bool {
        switch self {
        case .verified, .notDigestVerifiable:
            false
        case .missing, .sizeMismatch, .checksumMismatch:
            true
        }
    }
}
