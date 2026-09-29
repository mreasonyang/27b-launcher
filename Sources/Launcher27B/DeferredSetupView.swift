import SwiftUI

struct DeferredSetupView: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(preferences.localized("准备好时，再开始。"))
                .font(.largeTitle).bold()
            Text(preferences.localized("模型尚未准备好。继续设置后，就能在这台 Mac 上使用本机 AI。"))
                .foregroundStyle(.secondary)
            if let ownerPID = controller.otherInstanceOwnerPID { LauncherInstanceNotice(ownerPID: ownerPID) }
            Button(preferences.localized("继续设置"), action: controller.showQuickStart)
                .buttonStyle(.borderedProminent)
            if let error = controller.installationError { Text(error).foregroundStyle(.orange) }
        }
        .padding(32).frame(maxWidth: 660, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
}
