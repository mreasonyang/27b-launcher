import SwiftUI

/// A task-oriented setup page. File readiness and service readiness are distinct.
struct StudioInstallerOverlay: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences
    @State private var showsDownloadDetails = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                QuickStartSteps(step: controller.installationStatus == .ready ? (controller.isBusy || controller.isPreparingQuickStart || controller.status == .stopped ? 1 : 2) : controller.isDownloadInProgress ? 1 : 0)
                if let ownerPID = controller.otherInstanceOwnerPID {
                    LauncherInstanceNotice(ownerPID: ownerPID)
                }
                switch controller.installationStatus {
                case .checking:
                    ProgressView(preferences.localized("正在检查本地模型与运行环境…"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                case .required, .failed:
                    preparation
                case .installing:
                    download
                case .ready:
                    QuickStartReadyView(controller: controller)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Divider()
            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .task(id: controller.missingArtifacts) {
            await controller.refreshInstallationSpace()
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("在这台 Mac 上开始使用 AI", "下载 Bonsai 2 后，即可在本机聊天与辅助写作。默认设置即可开始。")
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(preferences.localized("这台 Mac"), value: controller.hardwareSummary)
                hardwareNotice
                Divider()
                LabeledContent(preferences.localized(controller.hasResumableDownload ? "待完成组件总大小" : "预计下载")) {
                    Text(controller.missingArtifacts.reduce(Int64(0)) { $0 + $1.expectedByteCount }, format: .byteCount(style: .file))
                        .monospacedDigit()
                }
                if controller.hasResumableDownload {
                    Label(preferences.localized("已保留上次的下载进度，将从中断处继续。"), systemImage: "arrow.clockwise.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !controller.reusedArtifacts.isEmpty {
                    Label(
                        preferences.localized("已复用已安装组件") + " "
                            + controller.reusedArtifacts.map {
                                preferences.localized($0.component.title)
                            }.joined(separator: preferences.localized("、")),
                        systemImage: "checkmark.circle"
                    )
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(preferences.localized("保存位置")).fontWeight(.medium)
                    Text(controller.modelStorageURL.path(percentEncoded: false))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preferences.localized("安装后可在设置中更改模型位置。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                spaceNotice
                Button(preferences.localized("查看下载内容")) { showsDownloadDetails = true }
                    .popover(isPresented: $showsDownloadDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.missingArtifacts) { artifact in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(preferences.localized(artifact.component.title))
                                        Spacer()
                                        Text(artifact.expectedByteCount, format: .byteCount(style: .file))
                                    }
                                    Text(preferences.localized(artifact.component.detail)).foregroundStyle(.secondary)
                                }.font(.callout).padding(.vertical, 5)
                            }
                            Text(preferences.localized("从 GitHub 和 Hugging Face 下载，完成后校验文件。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }.padding(16).frame(width: 420)
                    }
            }
            .launcherPanel(padding: 14)
            if let error = controller.installationError, controller.installationStatus == .failed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Button(preferences.localized("重新检测")) {
                    Task {
                        await controller.recheckInstallationIncludingModelStorage()
                        await controller.refreshInstallationSpace()
                    }
                }
            }
            Label(preferences.localized("首次下载需要联网；完成后，本机聊天可离线使用。"), systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hardwareNotice: some View {
        if let message = controller.hardwareIssueMessage {
            Label(message, systemImage: controller.canInstallModel ? "exclamationmark.triangle" : "xmark.octagon")
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(preferences.localized("满足当前硬件要求"), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var spaceNotice: some View {
        if let error = controller.installationSpaceError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
            Button(preferences.localized("重新检查空间")) { Task { await controller.refreshInstallationSpace() } }
        } else if let volumes = controller.installationSpace {
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.localizedFormat("安装需 %@ · 可用 %@",
                        volume.requiredBytes.formatted(.byteCount(style: .file).locale(preferences.language.locale)),
                        volume.availableBytes.formatted(.byteCount(style: .file).locale(preferences.language.locale))))
                    if volumes.count > 1 { Text(volume.volume.path).textSelection(.enabled) }
                    if !volume.isSufficient {
                        Text(preferences.localized("空间不足，请清理后重新检查。"))
                    }
                }
                .font(.callout)
                .foregroundStyle(volume.isSufficient ? Color.secondary : .primary)
            }
            if volumes.contains(where: { !$0.isSufficient }) {
                Button(preferences.localized("重新检查空间")) { Task { await controller.refreshInstallationSpace() } }
            }
        } else if !controller.missingArtifacts.isEmpty {
            ProgressView(preferences.localized("正在检查可用空间…"))
        }
    }

    private var download: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(downloadTitle, "模型准备好后，可在浏览器中打开本机聊天页面。")
            VStack(alignment: .leading, spacing: 16) {
                if let progress = controller.installationProgress {
                    HStack {
                        Text(preferences.localized(progress.component.title)).font(.headline)
                        Spacer()
                        if progress.phase == .downloading || progress.phase == .waitingForNetwork {
                            Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                                .font(.title2).monospacedDigit()
                        }
                    }
                    if progress.phase == .downloading || progress.phase == .waitingForNetwork {
                        ProgressView(value: progress.fractionCompleted)
                            .accessibilityLabel(preferences.localized("总下载进度"))
                        HStack {
                            Text(progress.overallCompletedBytes, format: .byteCount(style: .file))
                            Spacer()
                            Text(progress.overallTotalBytes, format: .byteCount(style: .file))
                        }.monospacedDigit().foregroundStyle(.secondary)
                        if progress.phase == .waitingForNetwork {
                            Label(preferences.localized("网络已中断，正在等待恢复并自动续传…"), systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.primary)
                        } else if let speed = progress.bytesPerSecond, speed > 0 {
                            HStack {
                                Text(Int64(speed).formatted(.byteCount(style: .file).locale(preferences.language.locale)) + "/s")
                                if let eta = progress.estimatedTimeRemaining {
                                    Text(preferences.localizedFormat("约剩 %lld 分钟", Int64(max(1, (eta / 60).rounded(.up)))))
                                }
                            }.font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(preferences.localized(progress.phase.title))
                        Text(preferences.localized("下载完成不代表已就绪，文件检查后还需要加载模型。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView(preferences.localized("正在准备下载…"))
                }
            }.launcherPanel(padding: 14)
            Text(preferences.localized("关闭窗口可继续准备。退出应用后，下次可继续下载。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var downloadTitle: String {
        switch controller.installationProgress?.phase {
        case .verifying: "正在检查下载的文件"
        case .copying, .installing: "正在配置本地环境"
        case .waitingForNetwork: "正在等待网络恢复"
        default: "正在下载 Bonsai 2"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.installationStatus {
        case .checking:
            Text(preferences.localized("正在检查这台 Mac")).foregroundStyle(.secondary)
        case .required, .failed:
            HStack(spacing: 8) {
                Text(preferences.localized("自动下载、校验并加载模型，完成后由你打开聊天。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(preferences.localized("稍后设置"), action: controller.dismissQuickStart)
                    .disabled(!controller.isPrimaryInstance)
                Button(preferences.localized(installTitle)) { Task { await controller.beginGuidedInstallation() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canBeginGuidedInstallation)
            }
        case .installing:
            HStack {
                Text(preferences.localized("已完成的下载会保留。"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if controller.isCancellingInstallation {
                    ProgressView(preferences.localized("正在暂停并保存下载进度…"))
                } else {
                    Button(preferences.localized(canPauseDownload ? "暂停下载" : "取消准备"), action: controller.cancelInstallation)
                }
            }
        case .ready:
            QuickStartReadyActions(controller: controller)
        }
    }

    private var canPauseDownload: Bool {
        controller.installationProgress == nil || controller.installationProgress?.phase == .downloading
            || controller.installationProgress?.phase == .waitingForNetwork
    }
    private var installTitle: String {
        if controller.hasDamagedComponents { return "修复损坏的组件" }
        return controller.hasResumableDownload ? "继续下载" : "下载并准备"
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preferences.localized(title)).font(.title2).bold().accessibilityAddTraits(.isHeader)
            Text(preferences.localized(subtitle)).foregroundStyle(.secondary)
        }
    }
}
