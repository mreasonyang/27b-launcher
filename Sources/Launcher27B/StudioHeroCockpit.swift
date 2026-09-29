import SwiftUI
import AppKit

struct StudioHeroCockpit: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences
    @State private var copied = false
    @State private var copiedAPI = false
    @State private var isPrimaryHovered = false
    @State private var isRestartHovered = false
    @State private var isStopHovered = false
    @State private var isConfirmingUnownedStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let ownerPID = controller.otherInstanceOwnerPID {
                LauncherInstanceNotice(ownerPID: ownerPID)
            }

            // Top: Model Identity & Live Status Badge
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Bonsai 2")
                            .font(.system(.title2, design: .rounded))
                            .bold()

                        badge("27B", color: .indigo)
                        badge("PQ2_0", color: .teal)
                        badge("Metal GPU", color: .blue)
                        badge("32K", color: .secondary)

                        if controller.ablationEnabled {
                            badge("OrcaBonsai", color: .purple)
                        }
                    }

                    Text(preferences.localized(controller.status.detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                // Live status capsule
                statusCapsule
            }

            Divider()

            if let unowned = controller.unownedServer {
                unownedServerNotice(pid: unowned.pid)
            }

            supervisionNotice

            // Middle: Integrated Action Buttons
            HStack(spacing: 10) {
                // Primary Action Button (Play / Chat / API copy / Adopt / Progress)
                Button(action: performPrimaryAction) {
                    HStack(spacing: 6) {
                        if controller.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: primaryIcon)
                                .offset(x: isPrimaryHovered ? 1.5 : 0)
                                .scaleEffect(isPrimaryHovered ? 1.08 : 1.0)
                                .animation(.spring(response: 0.25, dampingFraction: 0.68), value: isPrimaryHovered)
                                .accessibilityHidden(true)
                        }

                        Text(primaryTitle)
                    }
                }
                .buttonStyle(.studioPrimary)
                .disabled(!primaryActionEnabled)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(primaryTitle)
                .accessibilityHint(primaryHint)
                .task(id: copiedAPI) {
                    guard copiedAPI else { return }
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                    copiedAPI = false
                }
                .onChange(of: primaryAction) { _, _ in copiedAPI = false }
                .onHover { hovering in
                    isPrimaryHovered = hovering
                }

                // Secondary Control Buttons
                Button(action: { Task { await controller.restart() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isRestartHovered ? 45 : 0))
                            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isRestartHovered)
                            .accessibilityHidden(true)
                        Text(preferences.localized("重启"))
                    }
                }
                .buttonStyle(.studioSecondary(tint: LauncherTheme.accent))
                .disabled(!controller.canRestart)
                .help(preferences.localized("重新加载本地模型服务"))
                .accessibilityLabel(preferences.localized("重启"))
                .onHover { hovering in
                    isRestartHovered = hovering
                }

                Button(action: { Task { await controller.stop() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .scaleEffect(isStopHovered ? 1.15 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.68), value: isStopHovered)
                            .accessibilityHidden(true)
                        Text(preferences.localized("停止"))
                    }
                }
                .buttonStyle(.studioSecondary(destructive: true))
                .disabled(!controller.canStop)
                .help(preferences.localized("停止服务并释放模型内存"))
                .accessibilityLabel(preferences.localized("停止"))
                .onHover { hovering in
                    isStopHovered = hovering
                }

                Spacer(minLength: 0)
            }

            // Bottom: Endpoint banner
            let isRunning = controller.status == .running || controller.status == .external
            HStack(spacing: 10) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(preferences.localized("本地服务端点"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text(verbatim: controller.config.chatURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(isRunning ? .primary : .secondary)
                    .textSelection(.enabled)

                Text(endpointScopeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04), in: Capsule())

                Spacer()

                if isRunning {
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(
                            controller.config.chatURL.absoluteString,
                            forType: .string
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .scaleEffect(copied ? 1.2 : 1.0)
                                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: copied)
                                .accessibilityHidden(true)
                            Text(preferences.localized(copied ? "已复制" : "复制地址"))
                        }
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .primary)
                    }
                    .buttonStyle(.studioCopyPill(activeColor: .green))
                    .accessibilityLabel(
                        preferences.localized(copied ? "已复制" : "复制地址")
                    )
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } else {
                    Text(preferences.localized("待启动"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isRunning ? Color.green.opacity(0.08) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isRunning ? Color.green.opacity(0.2) : Color.primary.opacity(0.06),
                        lineWidth: 0.5
                    )
            )

            if isRunning && controller.effectiveBindMode == .allInterfaces {
                Label(
                    preferences.localized(
                        "局域网模式下内置聊天页面已停用；其他设备请将 127.0.0.1 换成这台 Mac 的 IP 地址，再使用上面的 API 地址连接。"
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if isRunning && controller.chatAffordanceIsUnreliable {
                // The preference says loopback, but this process never recorded
                // the live server's options, so a `--no-webui` server may be the
                // one answering. Say so instead of advertising a page that may
                // not exist.
                Label(
                    preferences.localized(
                        "运行中的服务参数未知，无法确认它是否提供内置聊天页面。接管并重启后可应用当前设置。"
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .launcherPanel()
        .confirmationDialog(
            preferences.localized("停止这个不受管理的服务？"),
            isPresented: $isConfirmingUnownedStop,
            titleVisibility: .visible
        ) {
            Button(preferences.localized("停止并释放内存与端口"), role: .destructive) {
                Task { await controller.stopUnownedServer() }
            }
            Button(preferences.localized("取消"), role: .cancel) {}
        } message: {
            Text(preferences.localized(
                "这会强制结束该模型进程，模型内存和端口 8080 会立即释放；未保存的请求会被中断。"
            ))
        }
    }

    // MARK: - Notices

    private func unownedServerNotice(pid: pid_t) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preferences.localized("模型服务正在运行，但不受本启动器管理"))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(unownedServerProse(pid: pid))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                // Only a listener identified as the launcher's own binary can be
                // adopted. For a stranger found through the port the action
                // returned `false` silently, so the button is not offered at all.
                if !controller.unownedServerIsForeign {
                    Button {
                        Task { await controller.adoptUnownedServer() }
                    } label: {
                        Label(preferences.localized("接管服务"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.studioPrimary)
                    .disabled(!controller.canAdoptUnownedServer)
                }

                Button {
                    isConfirmingUnownedStop = true
                } label: {
                    Label(preferences.localized("停止该进程"), systemImage: "stop.fill")
                }
                .buttonStyle(.studioSecondary(destructive: true))
                .disabled(!controller.canStopUnownedServer)

                Spacer()
            }
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
    }

    /// Describes the unmanaged listener according to what can actually be done
    /// with it.
    ///
    /// The single shipped sentence promised adoption in every case, so a foreign
    /// listener told the user to take it over — an action that returns `false`
    /// without any state change, because `discoverRunningServer()` finds nothing
    /// for a process that is not the launcher's binary.
    private func unownedServerProse(pid: pid_t) -> String {
        if controller.unownedServerIsForeign {
            return preferences.localizedFormat(
                "端口 8080 上有一个健康的模型服务（PID %lld），它不是由本启动器启动的，因此本启动器无法接管或控制它；模型仍占用内存。你只能停止该进程。",
                Int64(pid)
            )
        }
        return preferences.localizedFormat(
            "端口 8080 上有一个由本启动器启动、但当前未受本启动器管理的模型服务（PID %lld）；模型仍占用内存。你可以接管它，或停止该进程。",
            Int64(pid)
        )
    }

    @ViewBuilder
    private var supervisionNotice: some View {
        let notice = StudioPresentation.supervisionNotice(
            consecutiveFailures: controller.consecutiveStartFailures,
            isAutoRestartWanted: controller.isAutoRestartWanted,
            pauseReason: controller.supervisionPauseReason,
            crashesInCrashWindow: controller.crashesInCrashWindow
        )
        switch notice {
        case .none:
            EmptyView()

        case let .retrying(failures, retryAfterSeconds):
            if let key = notice.messageKey {
                supervisionBanner(
                    icon: "arrow.clockwise.circle.fill",
                    tint: .orange,
                    text: preferences.localizedFormat(
                        key,
                        Int64(failures),
                        Int64(retryAfterSeconds)
                    )
                )
            }

        case let .paused(failures):
            if let key = notice.messageKey {
                supervisionBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: preferences.localizedFormat(key, Int64(failures))
                )
            }

        case let .pausedByCrashLoop(crashes, _):
            if let key = notice.messageKey {
                supervisionBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: preferences.localizedFormat(
                        key,
                        Int64(
                            AutoRestartSupervision.crashRateWindow.components.seconds / 60
                        ),
                        Int64(crashes)
                    )
                )
            }

        case let .pausedAfterCrashes(failures, crashes):
            if let key = notice.messageKey {
                supervisionBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: preferences.localizedFormat(
                        key,
                        Int64(failures),
                        Int64(crashes)
                    )
                )
            }
        }
    }

    private func supervisionBanner(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var statusCapsule: some View {
        HStack(spacing: 8) {
            ZStack {
                if controller.status == .running {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                } else if controller.status == .external {
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                } else if controller.status == .starting || controller.status == .restarting || controller.status == .checking {
                    Circle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .padding(3)
                }
            }
            .accessibilityHidden(true)

            Text(preferences.localized(controller.status.title))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(controller.status == .stopped ? .secondary : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusBg, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(statusBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preferences.localizedFormat(
            "服务状态：%@",
            preferences.localized(controller.status.title)
        ))
    }

    private var endpointScopeLabel: String {
        if controller.status == .external {
            preferences.localized("外部服务")
        } else if controller.runningServerOptionsAreUnknown || controller.effectiveBindMode == nil {
            preferences.localized("运行参数未知")
        } else if controller.effectiveBindMode == .loopback {
            preferences.localized("仅本机")
        } else {
            preferences.localized("局域网共享")
        }
    }

    private var statusBg: Color {
        switch controller.status {
        case .running: Color.green.opacity(0.1)
        case .starting, .restarting, .checking: Color.orange.opacity(0.1)
        case .external: Color.blue.opacity(0.1)
        case .stopped, .stopping: Color.primary.opacity(0.04)
        }
    }

    private var statusBorder: Color {
        switch controller.status {
        case .running: Color.green.opacity(0.3)
        case .starting, .restarting, .checking: Color.orange.opacity(0.3)
        case .external: Color.blue.opacity(0.3)
        case .stopped, .stopping: Color.primary.opacity(0.08)
        }
    }

    // MARK: - Primary action

    private var primaryAction: StudioPrimaryAction {
        StudioPresentation.primaryAction(
            status: controller.status,
            isBusy: controller.isBusy,
            hasUnownedServer: controller.unownedServer != nil,
            unownedServerIsForeign: controller.unownedServerIsForeign,
            canOpenChat: controller.canOpenChat,
            chatOptionsAreUnknown: controller.chatAffordanceIsUnreliable
        )
    }

    private var primaryTitle: String {
        switch primaryAction {
        case .busy:
            preferences.localized(controller.status.title)
        case .openChat:
            preferences.localized("打开聊天")
        case .copyAPIAddress:
            preferences.localized(copiedAPI ? "已复制" : "复制 API 地址")
        case .adoptUnownedServer:
            preferences.localized("接管服务")
        case .start:
            preferences.localized("启动模型")
        }
    }

    private var primaryIcon: String {
        switch primaryAction {
        case .busy, .start:
            "play.fill"
        case .openChat:
            "bubble.left.and.bubble.right.fill"
        case .copyAPIAddress:
            copiedAPI ? "checkmark" : "doc.on.doc"
        case .adoptUnownedServer:
            "arrow.down.circle"
        }
    }

    private var primaryActionEnabled: Bool {
        StudioPresentation.isPrimaryActionEnabled(
            primaryAction,
            canStart: controller.canStart,
            isBusy: controller.isBusy
        )
    }

    private var primaryHint: String {
        switch primaryAction {
        case .busy:
            preferences.localized("正在处理，请稍候")
        case .openChat:
            preferences.localized("在系统默认浏览器中打开本地聊天页面")
        case .copyAPIAddress:
            controller.chatAffordanceIsUnreliable
                ? preferences.localized("本启动器无法确认这个服务是否提供内置聊天页面；复制 API 地址供其他设备或客户端使用")
                : preferences.localized("局域网模式下内置聊天页面已停用；复制 API 地址供其他设备或客户端使用")
        case .adoptUnownedServer:
            preferences.localized("接管由本启动器启动、但当前未受本启动器管理的模型服务")
        case .start:
            preferences.localized("加载 Bonsai 2 模型并启动本地服务")
        }
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .busy:
            break
        case .openChat:
            controller.openChat()
        case .copyAPIAddress:
            NSPasteboard.general.clearContents()
            copiedAPI = NSPasteboard.general.setString(
                StudioPresentation.apiAddress(for: controller.config),
                forType: .string
            )
        case .adoptUnownedServer:
            Task { await controller.adoptUnownedServer() }
        case .start:
            Task { await controller.start() }
        }
    }
}
