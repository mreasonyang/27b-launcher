import SwiftUI

struct DisplayPreferencesPanel: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            if let error = controller.settingsValidationError {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button(preferences.localized("重置无效设置")) { controller.resetInvalidSettings() }
                        .disabled(!controller.isPrimaryInstance || controller.isBusy)
                }
            }
            Section(preferences.localized("显示与语言")) {
                Picker(preferences.localized("语言"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .accessibilityHint(preferences.localized("立即切换应用界面语言"))

                Picker(preferences.localized("外观"), selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(preferences.localized(appearance.titleKey)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(preferences.localized("无障碍模式"), isOn: $preferences.accessibilityModeEnabled)
                    .toggleStyle(.switch)
            } footer: {
                Text(preferences.localized("提高对比度，减少透明和动态效果"))
            }

            Section(preferences.localized("API 访问")) {
                Text(preferences.localized("局域网 API 使用钥匙串中的密钥。HTTP 不加密请求；仅在可信网络使用。"))
                    .font(.caption)
                HStack {
                    Button(preferences.localized("复制 API 密钥")) { controller.copyAPIKey() }
                    Button(preferences.localized("轮换密钥并重启")) { Task { await controller.rotateAPIKey() } }
                }
                .disabled(!controller.isPrimaryInstance || controller.isBusy || controller.chatAffordanceIsUnreliable)
                Text(preferences.localized("复制的密钥在 60 秒后清除；轮换后需要更新所有客户端。局域网模式不采集 Token 统计。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ModelStorageSettingsSection(controller: controller)
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 650)
        .task {
            await controller.refreshModelStorage()
        }
    }
}
