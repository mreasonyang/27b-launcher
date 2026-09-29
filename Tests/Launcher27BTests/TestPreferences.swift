import Foundation
@testable import Launcher27B

enum TestPreferences {
    @MainActor static func chinese() -> AppPreferences {
        let name = "27B-test-language-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.language = .simplifiedChinese
        defaults.removePersistentDomain(forName: name)
        return preferences
    }
}
