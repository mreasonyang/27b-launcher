import SwiftUI

struct ModelStorageMigrationStatusView: View {
    let progress: ModelStorageMigrationProgress
    let isCancelling: Bool
    let cancel: () -> Void
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preferences.localized(progress.phase.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    progress.fractionCompleted,
                    format: .percent.precision(.fractionLength(0))
                )
                .font(.caption.monospacedDigit())
            }

            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)

            HStack(spacing: 6) {
                Text(progress.stageCompletedBytes, format: .byteCount(style: .file))
                Text("/")
                Text(progress.stageTotalBytes, format: .byteCount(style: .file))
                if let speed = progress.bytesPerSecond, speed > 0 {
                    Text("·")
                    Text(Int64(speed).formatted(.byteCount(style: .file)) + "/s")
                }
                if let eta = progress.estimatedTimeRemaining, eta > 0 {
                    Text("·")
                    Text(preferences.localized("预计剩余"))
                    Text(formattedDuration(eta))
                }
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            HStack {
                Button(preferences.localized("取消迁移"), role: .cancel, action: cancel)
                    .disabled(isCancelling)
                if isCancelling {
                    ProgressView()
                        .controlSize(.small)
                    Text(preferences.localized("正在安全停止迁移…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded()), 0)
        if seconds < 60 {
            return preferences.localizedFormat("约 %lld 秒", Int64(seconds))
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return preferences.localizedFormat("约 %lld 分钟", Int64(minutes))
        }
        return preferences.localizedFormat(
            "约 %lld 小时 %lld 分钟",
            Int64(minutes / 60),
            Int64(minutes % 60)
        )
    }
}
