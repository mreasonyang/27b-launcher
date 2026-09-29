import AppKit
import SwiftUI

struct ConnectionCopyField: View {
    let title: String
    let value: String
    let copyTitle: String
    @Environment(AppPreferences.self) private var preferences
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).fontWeight(.medium)
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: value).font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? preferences.localized("已复制") : copyTitle) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(value, forType: .string)
                }
                .accessibilityLabel(copyTitle)
                .accessibilityValue(copied ? preferences.localized("已复制") : "")
                .task(id: copied) {
                    guard copied else { return }
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                    copied = false
                }
            }
        }
        .onChange(of: value) { _, _ in copied = false }
    }
}
