import SwiftUI

struct QuickStartReadyActions: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        HStack(spacing: 14) {
            Text(preferences.localized("默认设置即可开始。"))
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(preferences.localized("进入主界面"), action: controller.dismissQuickStart)
                .disabled(controller.isBusy || controller.isPreparingQuickStart)
            if controller.status == .running && controller.canOpenChat && !controller.chatAffordanceIsUnreliable {
                Button(preferences.localized(controller.chatOpenError == nil ? "开始聊天" : "重试打开")) {
                    if controller.openChat() { controller.dismissQuickStart() }
                }.buttonStyle(.borderedProminent)
            } else if controller.canStart && !controller.isPreparingQuickStart {
                Button(preferences.localized(controller.latestError == nil ? "启动模型" : "重试启动")) {
                    Task { await controller.prepareModelForQuickStart() }
                }.buttonStyle(.borderedProminent)
            }
        }
    }
}
