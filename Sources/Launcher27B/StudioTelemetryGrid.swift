import SwiftUI

struct StudioTelemetryGrid: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        let isRunning = controller.status == .running || controller.status == .external
        let usage = controller.tokenUsage
        let speedText = usage.map {
            $0.generatedTokensPerSecond.formatted(
                .number
                    .precision(.fractionLength(1))
                    .locale(preferences.language.locale)
            )
        } ?? "--"
        let totalTokensText = usage?.totalTokens.formatted(
            .number.locale(preferences.language.locale)
        ) ?? "--"
        let maximumContextText = usage?.maximumContextTokens.formatted(
            .number.locale(preferences.language.locale)
        ) ?? "--"
        let requestStatusText = usage.map {
            "\($0.activeRequests) \(preferences.localized("活动请求"))"
        } ?? (isRunning ? preferences.localized("统计不可用") : preferences.localized("待启动"))

        HStack(spacing: 12) {
            // Card 1: Speed
            telemetryCard(
                icon: "bolt.fill",
                iconColor: isRunning ? .orange : .secondary,
                title: preferences.localized("生成速度"),
                primaryValue: speedText,
                unit: "tok/s",
                accessibilityLabel: preferences.localizedFormat(
                    "生成速度：%@ tok/s；%@",
                    speedText,
                    requestStatusText
                )
            ) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(usage?.activeRequests ?? 0 > 0 ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(requestStatusText)
                        .help(controller.tokenUsageError ?? requestStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 24)
            }

            // Card 2: Token Throughput & Ratio
            telemetryCard(
                icon: "chart.xyaxis.line",
                iconColor: isRunning ? .blue : .secondary,
                title: preferences.localized("Token 用量"),
                primaryValue: totalTokensText,
                unit: preferences.localized("合计"),
                accessibilityLabel: preferences.localizedFormat(
                    "Token 用量：合计 %@",
                    totalTokensText
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    if let usage, usage.totalTokens > 0 {
                        let total = Double(usage.totalTokens)
                        let promptRatio = Double(usage.promptTokens) / total
                        let generatedRatio = Double(usage.generatedTokens) / total

                        GeometryReader { proxy in
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.blue)
                                    .frame(width: max(proxy.size.width * promptRatio - 1, 3))

                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.mint)
                                    .frame(width: max(proxy.size.width * generatedRatio - 1, 3))
                            }
                        }
                        .frame(height: 5)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

                        HStack {
                            Text(preferences.localizedFormat(
                                "输入: %lld%%",
                                Int64(promptRatio * 100)
                            ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(preferences.localizedFormat(
                                "输出: %lld%%",
                                Int64(generatedRatio * 100)
                            ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 5)

                        HStack {
                            Text(preferences.localized("输入: --%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(preferences.localized("输出: --%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 24)
            }

            // Card 3: Context Window
            telemetryCard(
                icon: "text.alignleft",
                iconColor: isRunning ? .purple : .secondary,
                title: preferences.localized("上下文峰值"),
                primaryValue: maximumContextText,
                unit: "/ 32K",
                accessibilityLabel: preferences.localizedFormat(
                    "上下文峰值：%@ / 32K",
                    maximumContextText
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    if let usage {
                        let contextRatio = min(Double(usage.maximumContextTokens) / 32768.0, 1.0)

                        ProgressView(value: contextRatio)
                            .progressViewStyle(.linear)
                            .tint(Color.purple)

                        HStack {
                            Text(preferences.localizedFormat(
                                "占用: %lld%%",
                                Int64(contextRatio * 100)
                            ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(preferences.localizedFormat(
                                "复用: %lld",
                                Int64(usage.cachedPromptTokens)
                            ))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(value: 0.0)
                            .progressViewStyle(.linear)
                            .tint(Color.secondary.opacity(0.2))

                        HStack {
                            Text(preferences.localized("占用: --%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(preferences.localized("复用: --"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 24)
            }
        }
    }

    private func telemetryCard<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        primaryValue: String,
        unit: String,
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(primaryValue)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .bold()
                    .textSelection(.enabled)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            content()
        }
        .frame(height: 102)
        .launcherPanel(padding: 14)
        // VoiceOver read three bare numbers with no unit or meaning; the card is
        // one metric, so expose it as a single labelled element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
