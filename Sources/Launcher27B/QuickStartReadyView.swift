import SwiftUI
import AppKit

struct QuickStartReadyView: View {
    @Bindable var controller: ServiceController
    @Environment(AppPreferences.self) private var preferences
    @State private var copied = false

    private var chatReady: Bool {
        controller.status == .running && controller.canOpenChat && !controller.chatAffordanceIsUnreliable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preferences.localized(title)).font(.title2).bold().accessibilityAddTraits(.isHeader)
            if controller.isBusy || controller.isPreparingQuickStart {
                ProgressView(preferences.localized("正在把模型加载到内存中，请稍候。"))
                Text(preferences.localized("准备完成后会留在此页，由你打开聊天。"))
            } else if chatReady {
                Label(preferences.localized("Bonsai 2 已在这台 Mac 上运行。"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let error = controller.chatOpenError {
                    HStack(alignment: .top, spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(preferences.localized("复制地址")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.config.chatURL.absoluteString, forType: .string)
                        }
                    }
                } else {
                    Text(preferences.localized("点击“开始聊天”，在系统默认浏览器中打开本机聊天页面。"))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(preferences.localized("试试这句话")).font(.headline)
                        Spacer()
                        Button(preferences.localized(copied ? "已复制" : "复制示例")) {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(preferences.localized("用通俗的话解释一下，什么是大语言模型？"), forType: .string)
                        }
                        .task(id: copied) {
                            guard copied else { return }
                            do { try await Task.sleep(for: .seconds(2)) }
                            catch { return }
                            copied = false
                        }
                        .onChange(of: preferences.language) { _, _ in copied = false }
                    }
                    Text(preferences.localized("用通俗的话解释一下，什么是大语言模型？"))
                        .textSelection(.enabled)
                }.launcherPanel(padding: 12)
                QuickStartConnectionInfo(controller: controller)
            } else {
                Text(preferences.localized("文件已安装。启动模型后，即可使用本机服务。"))
                    .foregroundStyle(.secondary)
                if let error = controller.latestError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
                    Button(preferences.localized("查看日志"), action: controller.revealLogs)
                }
                if controller.status == .external || controller.status == .running {
                    Text(preferences.localized("当前服务无法确认聊天可用，或正在使用 API 模式。请进入主界面查看连接与接管选项。"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var title: String {
        if controller.isBusy || controller.isPreparingQuickStart { return "正在加载模型" }
        if chatReady { return "准备好了，开始第一段对话" }
        if controller.status == .running || controller.status == .external { return "本机服务状态" }
        return controller.latestError == nil ? "模型文件已就绪" : "文件已安装，模型尚未启动"
    }
}
