import Foundation
import Testing
@testable import Launcher27B

struct AppPreferencesTests {
    @Test
    func supportedLanguagesExposeExpectedLocalesAndNames() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["zh-Hans", "zh-Hant", "en", "es"])
        #expect(AppLanguage.simplifiedChinese.nativeName == "简体中文")
        #expect(AppLanguage.traditionalChinese.nativeName == "繁體中文")
        #expect(AppLanguage.english.nativeName == "English")
        #expect(AppLanguage.spanish.nativeName == "Español")
    }

    @MainActor
    @Test
    func preferencesPersistAcrossInstances() throws {
        let suiteName = "Launcher27BTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppPreferences(defaults: defaults)
        first.language = .spanish
        first.appearance = .dark
        first.accessibilityModeEnabled = true

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.language == .spanish)
        #expect(restored.appearance == .dark)
        #expect(restored.accessibilityModeEnabled)
    }
}
