import AppKit
import SwiftUI

struct ModelStorageSettingsSection: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    @State private var isVerifying = false
    @State private var verificationCompleted = 0
    @State private var verificationTotal = 0
    @State private var verificationResults: [InstallationComponent: ArtifactVerification] = [:]
    @State private var verificationMessage: VerificationMessage?
    @State private var recoverableArtifacts: [InstallationArtifact] = []
    @State private var isRecovering = false

    var body: some View {
        Section {
            LabeledContent(preferences.localized("实际位置")) {
                Text(controller.modelStorageURL.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        controller.modelStorageConfigurationUnavailable ? Color.orange : Color.secondary
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .help(controller.modelStorageURL.path(percentEncoded: false))
            }

            LabeledContent(preferences.localized("占用空间")) {
                if controller.modelStorageIsAvailable {
                    Text(controller.modelStorageBytes, format: .byteCount(style: .file))
                        .monospacedDigit()
                } else if controller.modelStorageConfigurationUnavailable {
                    Text(preferences.localized("位置不可用"))
                        .foregroundStyle(.orange)
                } else {
                    Text(preferences.localized("安装时自动创建"))
                        .foregroundStyle(.secondary)
                }
            }



            HStack {
                Button(preferences.localized("在 Finder 中显示")) {
                    controller.revealModels()
                }
                .disabled(!controller.modelStorageIsAvailable || controller.isModelMigrationInProgress)

                Button(preferences.localized("更改位置…"), action: chooseDestination)
                    .disabled(
                        !controller.modelStorageIsAvailable
                            || controller.isModelMigrationInProgress
                            || controller.isBusy
                            || controller.installationStatus != .ready
                            || !controller.isPrimaryInstance
                    )

                Spacer()
            }

            verificationRow

            if let progress = controller.modelMigrationProgress {
                ModelStorageMigrationStatusView(
                    progress: progress,
                    isCancelling: controller.isCancellingModelMigration,
                    cancel: controller.cancelModelMigration
                )
            }

            if let outcome = controller.modelMigrationOutcome {
                Label(outcome.message, systemImage: outcome.systemImage)
                    .font(.caption)
                    .foregroundStyle(outcomeTint(outcome))
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
            }

            // The outcome above is in-memory only, so a retained duplicate went
            // invisible after a relaunch. This line is rebuilt from the persisted
            // record and names the path that still occupies the space.
            if controller.modelMigrationOutcome == nil,
               let retained = controller.retainedSourceModelMessage {
                Label(retained, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
        } header: {
            Text(preferences.localized("模型存储"))
        } footer: {
            Text(preferences.localized("迁移时会暂停模型服务；校验成功后自动恢复。目标位置会创建 Bonsai2 Models 文件夹。"))
        }
    }

    // MARK: - Full-content verification

    /// A model file that is truncated, resized or bit-rotted passes the cheap
    /// size check the installer uses, so the only symptom was a health-check
    /// timeout with no way forward. This hashes the installed artifacts on
    /// demand and reports which ones need to be downloaded again.
    @ViewBuilder
    private var verificationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await verifyInstalledArtifacts() }
                } label: {
                    Label(preferences.localized("校验文件"), systemImage: "checkmark.shield")
                }
                .disabled(!canVerifyArtifacts)
                .help(preferences.localized("逐个计算已安装文件的校验和，确认模型文件没有损坏"))

                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                    Text(preferences.localizedFormat(
                        "正在校验 %lld/%lld…",
                        Int64(verificationCompleted),
                        Int64(verificationTotal)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if isRecovering {
                    ProgressView()
                        .controlSize(.small)
                    Text(preferences.localized("正在从保留的下载中恢复…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if verificationTotal > 0 && (isVerifying || !verificationResults.isEmpty) {
                ProgressView(
                    value: Double(verificationCompleted),
                    total: Double(max(verificationTotal, 1))
                )
                .progressViewStyle(.linear)
            }

            if !verificationResults.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(InstallationComponent.allCases) { component in
                        if let result = verificationResults[component] {
                            HStack(spacing: 6) {
                                Text(preferences.localized(component.title))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(verificationLabel(result))
                                    .foregroundStyle(result.needsRepair ? Color.red : Color.green)
                            }
                            .font(.caption2)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }

            if let message = localizedVerificationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        StudioPresentation.componentsNeedingRepair(in: verificationResults).isEmpty
                            ? Color.secondary
                            : Color.red
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !StudioPresentation.componentsNeedingRepair(in: verificationResults).isEmpty {
                Button(preferences.localized("修复损坏的组件")) {
                    Task { await controller.repairDamagedArtifacts() }
                }
                .disabled(controller.isBusy || !controller.isPrimaryInstance || isVerifying || isRecovering)
            }

            if !recoverableArtifacts.isEmpty {
                Button {
                    Task { await recoverPreservedDownloads() }
                } label: {
                    Label(
                        preferences.localized("从保留的下载中恢复"),
                        systemImage: "arrow.clockwise.circle"
                    )
                }
                .disabled(isVerifying || isRecovering || !controller.isPrimaryInstance || controller.isBusy)
                .help(preferences.localized("重新校验上次保留的下载文件；校验通过后可直接安装，无需重新下载"))
            }
        }
    }

    private var canVerifyArtifacts: Bool {
        (controller.installationStatus == .ready || controller.installationStatus == .failed || controller.installationStatus == .required)
            && controller.isPrimaryInstance
            && controller.modelStorageIsAvailable
            && !controller.isBusy
            && !isVerifying
            && !isRecovering
    }

    @MainActor
    private func verifyInstalledArtifacts() async {
        let inspector = InstallationInspector()
        let artifacts = InstallationCatalog().artifacts(for: controller.config)
        do {
            let targets = try inspector.artifactsRequiringVerification(
                from: artifacts,
                config: controller.config
            )

            guard !targets.isEmpty else {
                verificationResults = [:]
                recoverableArtifacts = []
                verificationCompleted = 0
                verificationTotal = 0
                verificationMessage = .noFiles
                return
            }

            isVerifying = true
            verificationResults = [:]
            recoverableArtifacts = []
            verificationMessage = nil
            verificationCompleted = 0
            verificationTotal = targets.count

            var results: [InstallationComponent: ArtifactVerification] = [:]
            var damaged: [InstallationArtifact] = []

            for artifact in targets {
                try Task.checkCancellation()
                let result = try await inspector.verify(
                    artifact,
                    config: controller.config
                )
                results[artifact.component] = result
                controller.recordVerification([artifact.component: result])
                if result.needsRepair, preservedDownloadExists(for: artifact) {
                    damaged.append(artifact)
                }
                verificationCompleted += 1
                verificationResults = results
            }

            recoverableArtifacts = damaged
            isVerifying = false
            verificationMessage = .complete
        } catch {
            isVerifying = false
            verificationMessage = .failure(error)
        }
    }

    @MainActor
    private func recoverPreservedDownloads() async {
        guard !recoverableArtifacts.isEmpty else { return }
        isRecovering = true

        do {
            let installer = BonsaiInstaller(config: controller.config)
            var recovered = 0
            for artifact in recoverableArtifacts {
                try Task.checkCancellation()
                if try await installer.reverifyPreservedDownload(for: artifact) {
                    recovered += 1
                }
            }

            isRecovering = false
            controller.recheckInstallation()
            await verifyInstalledArtifacts()
            verificationMessage = .recovered(recovered)
        } catch {
            isRecovering = false
            verificationMessage = .failure(error)
        }
    }

    private enum VerificationMessage {
        case noFiles
        case complete
        case recovered(Int)
        case failure(any Error)
    }

    private var localizedVerificationMessage: String? {
        switch verificationMessage {
        case nil:
            nil
        case .noFiles:
            preferences.localized("没有可校验的模型文件；请先完成安装。")
        case .complete:
            verificationSummary(for: verificationResults)
        case .recovered(let count):
            preferences.localizedFormat(
                "已从保留的下载中恢复 %lld 个文件；上面的校验结果已更新。",
                Int64(count)
            )
        case .failure(let error):
            controller.localizedMessage(for: error)
        }
    }

    private func verificationSummary(
        for results: [InstallationComponent: ArtifactVerification]
    ) -> String {
        let damaged = StudioPresentation.componentsNeedingRepair(in: results)
        guard !damaged.isEmpty else {
            return preferences.localizedFormat(
                "校验完成：%lld 个文件全部正常。",
                Int64(results.count)
            )
        }

        let names = damaged
            .map { preferences.localized($0.title) }
            .joined(separator: preferences.localized("、"))
        return preferences.localizedFormat(
            "校验完成：%@ 校验未通过，建议重新下载这些组件。",
            names
        )
    }

    private func verificationLabel(_ result: ArtifactVerification) -> String {
        switch result {
        case .verified:
            preferences.localized("正常")
        case .missing:
            preferences.localized("文件缺失")
        case .sizeMismatch:
            preferences.localized("大小不符")
        case .checksumMismatch:
            preferences.localized("校验和不符")
        case .notDigestVerifiable:
            preferences.localized("结构校验通过")
        }
    }

    private func preservedDownloadExists(for artifact: InstallationArtifact) -> Bool {
        FileManager.default.fileExists(
            atPath: preservedDownloadURL(for: artifact).path
        )
    }

    private func preservedDownloadURL(for artifact: InstallationArtifact) -> URL {
        controller.config.downloadsDirectory.appending(
            path: "\(artifact.component.rawValue).download"
        )
    }

    private func outcomeTint(_ outcome: ModelStorageMigrationOutcome) -> Color {
        if outcome.isSuccess {
            return .green
        }
        return outcome.isFailure ? .red : .secondary
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = preferences.localized("选择新的模型存储位置")
        panel.message = preferences.localized("将在所选文件夹内创建 Bonsai2 Models 文件夹")
        panel.prompt = preferences.localized("选择位置")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.beginModelMigration(to: url)
    }
}
