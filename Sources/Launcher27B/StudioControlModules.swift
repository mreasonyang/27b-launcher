import SwiftUI
import AppKit

struct StudioControlModules: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences
    @State private var copiedAPI = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            orcabonsaiCard
            networkCard
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - OrcaBonsai Card
    private var orcabonsaiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(Color.purple)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("OrcaBonsai")
                            .font(.headline)

                        if controller.ablationEnabled {
                            Text(controller.ablationStrength.rawValue + "×")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.1), in: Capsule())
                        }
                    }

                    Text(preferences.localized("调整模型的拒答倾向"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    preferences.localized("启用 OrcaBonsai"),
                    isOn: Binding(
                        get: { controller.ablationEnabled },
                        set: { enabled in
                            Task { await controller.setAblationEnabled(enabled) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(controller.isBusy || !controller.isPrimaryInstance)
            }

            Divider()

            if controller.ablationEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    // Segmented Strength Picker
                    Picker(
                        preferences.localized("拒答减弱程度"),
                        selection: Binding(
                            get: { controller.ablationStrength },
                            set: { strength in
                                Task { await controller.setAblationStrength(strength) }
                            }
                        )
                    ) {
                        ForEach(AblationStrength.allCases) { strength in
                            Text(strength.rawValue + "×").tag(strength)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(controller.isBusy || !controller.isPrimaryInstance)

                    // Strength Details Card
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preferences.localized(controller.ablationStrength.title))
                            .font(.caption)
                            .fontWeight(.semibold)

                        Text(preferences.localized(controller.ablationStrength.explanation))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.purple.opacity(0.12), lineWidth: 0.5)
                    )

                    // Safety Warning Banner
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(preferences.localized("减少拒答不等于输出安全或正确"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.localized("原始对齐模式"))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(preferences.localized("模块已关闭，Bonsai 2 保留官方默认的安全审查与拒答策略。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .launcherPanel(padding: 16)
    }

    // MARK: - Network Card
    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(Color.blue)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(preferences.localized("监听范围"))
                        .font(.headline)
                    Text(networkScopeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Mode Selector
            Picker(preferences.localized("监听范围"), selection: Binding(
                get: { controller.bindMode },
                set: { mode in Task { await controller.setBindMode(mode) } }
            )) {
                ForEach(ServerBindMode.allCases) { mode in
                    Text(preferences.localized(mode.titleKey)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(controller.isBusy || !controller.isPrimaryInstance)
            .accessibilityHint(preferences.localized("切换到“所有网络接口”前会要求确认"))
            // `setBindMode` parks an unconfirmed switch to `.allInterfaces` in
            // `pendingBindMode`; without this dialog the picker silently snapped
            // back with no explanation.
            .confirmationDialog(
                preferences.localized("在所有网络接口上共享模型服务？"),
                isPresented: Binding(
                    get: { controller.isBindModeChangePending },
                    set: { isPresented in
                        if !isPresented { controller.cancelPendingBindMode() }
                    }
                ),
                titleVisibility: .visible,
                presenting: controller.pendingBindMode
            ) { mode in
                Button(preferences.localized("确认开启局域网共享"), role: .destructive) {
                    // Dismissal clears pendingBindMode before this task may run.
                    // Use the value captured when SwiftUI presented the dialog.
                    Task { await controller.confirmBindMode(mode) }
                }
                Button(preferences.localized("取消"), role: .cancel) {
                    controller.cancelPendingBindMode()
                }
            } message: { _ in
                Text(preferences.localized(
                    "服务将监听所有网络接口，并要求 API 密钥。网页聊天将关闭。HTTP 不加密密钥或对话内容，请仅在可信网络使用；可在设置中复制和轮换密钥。"
                ))
            }

            // The picker edits the *preference* (what the next launch will ask
            // for). When a failed restart leaves the existing scope in place the
            // control and the live service disagree, so say which one is running
            // rather than letting the picker imply the change took effect.
            if let actualMode = controller.effectiveBindMode, actualMode != controller.bindMode {
                Label(
                    preferences.localized(
                        "运行中的服务仍在按上一次的监听范围运行；新的监听范围将在重启成功后生效。"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Keyed on the *running* server's actual scope, never on the
            // preference: a bind-mode switch can update the preference before a
            // restart succeeds, while the unauthenticated service is still listening.
            if controller.isExposedToLAN {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        preferences.localized(
                            "局域网 API 已启用密钥认证。HTTP 不加密传输；请仅在可信网络使用。密钥管理位于设置。"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    Text(preferences.localized(
                        "请在“系统设置 > 网络 > 防火墙”中开启防火墙，并仅在可信网络中使用。"
                    ))
                    .padding(.leading, 22)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if controller.isExposedToLAN {
                ForEach(NetworkEndpoints.localIPv4(), id: \.self) { address in
                    Text("http://\(address):8080/v1")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            // API Endpoint Copy Row
            HStack(spacing: 8) {
                Text(preferences.localized("本机 API 端点"))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text(controller.config.chatURL.appending(path: "v1").absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    copiedAPI = NSPasteboard.general.setString(
                        controller.config.chatURL.appending(path: "v1").absoluteString,
                        forType: .string
                    )
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedAPI ? "checkmark" : "doc.on.doc")
                            .scaleEffect(copiedAPI ? 1.2 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: copiedAPI)
                            .accessibilityHidden(true)
                        Text(preferences.localized(copiedAPI ? "已复制" : "复制"))
                    }
                    .font(.caption2)
                    .foregroundStyle(copiedAPI ? .green : .primary)
                }
                .buttonStyle(.studioCopyPill(activeColor: .blue))
                .accessibilityLabel(preferences.localized(copiedAPI ? "已复制" : "复制"))
                .task(id: copiedAPI) {
                    guard copiedAPI else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copiedAPI = false
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Divider()

            // Auto-start on login
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.caption2)
                    .foregroundStyle(Color.green)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preferences.localized("登录时自动运行"))
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(preferences.localized("登录这台 Mac 后自动加载模型"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    preferences.localized("登录时自动运行"),
                    isOn: Binding(
                        get: { controller.autoStartEnabled },
                        set: { enabled in
                            Task { await controller.setAutoStart(enabled) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(controller.isBusy || !controller.isPrimaryInstance)
            }

            if controller.loginItemRequiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(preferences.localized("请在系统设置 > 登录项中允许 27B Launcher"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .launcherPanel(padding: 16)
    }

    private var networkScopeDescription: String {
        if controller.status == .external {
            preferences.localized("外部服务 · 监听范围未知")
        } else if controller.runningServerOptionsAreUnknown || controller.effectiveBindMode == nil {
            preferences.localized("运行参数未知")
        } else if controller.effectiveBindMode == .loopback {
            "127.0.0.1 (\(preferences.localized("仅本机")))"
        } else {
            "0.0.0.0 (\(preferences.localized("局域网共享")))"
        }
    }
}
