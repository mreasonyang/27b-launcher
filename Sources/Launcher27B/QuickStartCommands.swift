import SwiftUI

struct QuickStartCommands: Commands {
    let controller: ServiceController
    let preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(preferences.localized("快速入门")) {
                controller.showQuickStart()
                openWindow(id: "studio")
            }
        }
    }
}
