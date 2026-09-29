import SwiftUI

struct QuickStartSteps: View {
    let step: Int
    @Environment(AppPreferences.self) private var preferences
    private let titles = ["准备", "安装与加载", "开始聊天"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(titles.indices, id: \.self) { index in
                if index > 0 { Rectangle().fill(.separator).frame(height: 1).accessibilityHidden(true) }
                HStack(spacing: 7) {
                    Image(systemName: index < step ? "checkmark.circle.fill" : "\(index + 1).circle\(index == step ? ".fill" : "")")
                        .accessibilityHidden(true)
                    Text(preferences.localized(titles[index]))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(index == step ? Color.accentColor : .secondary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(index == step ? preferences.localized("当前步骤") : "")
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preferences.localized(titles[step]))
        .accessibilityValue(preferences.localized("当前步骤"))
        .id(step)
    }
}
