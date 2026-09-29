import SwiftUI

struct QuickStartConnectionInfo: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preferences.localized("连接其他应用")).font(.headline)
            Text(preferences.localized("在其他应用中选择“OpenAI 兼容”，然后填写以下信息。"))
                .font(.callout).foregroundStyle(.secondary)
            ConnectionCopyField(title: preferences.localized("API 地址（Base URL）"),
                value: StudioPresentation.apiAddress(for: controller.config),
                copyTitle: preferences.localized("复制 API 地址"))
            if let modelID = controller.connectionModelID {
                ConnectionCopyField(title: preferences.localized("模型 ID"), value: modelID,
                    copyTitle: preferences.localized("复制模型 ID"))
            } else if controller.connectionModelIDFailed {
                Text(preferences.localized("暂时无法读取模型 ID。请重试，我们会自动从本机服务获取。"))
                    .font(.callout)
                Button(preferences.localized("重新读取模型 ID")) {
                    Task { await controller.refreshConnectionModelID() }
                }
            } else {
                ProgressView(preferences.localized("正在读取模型 ID…"))
            }
            Text(preferences.localized("API 密钥：本机连接无需密钥；如果应用要求必填，可填写 local。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(preferences.localized("这些信息用于连接这台 Mac 上的应用。"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .launcherPanel(padding: 12)
        .task { await controller.refreshConnectionModelID() }
    }
}
