import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.languageKey) }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    var accessibilityModeEnabled: Bool {
        didSet { defaults.set(accessibilityModeEnabled, forKey: Self.accessibilityModeKey) }
    }

    var setupDeferred: Bool {
        didSet { defaults.set(setupDeferred, forKey: "setupDeferred") }
    }

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }

    private let defaults: UserDefaults

    private static let languageKey = "appLanguage"
    private static let appearanceKey = "appAppearance"
    private static let accessibilityModeKey = "accessibilityModeEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.setupDeferred = defaults.bool(forKey: "setupDeferred")
        self.onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        self.language = AppLanguage(
            rawValue: defaults.string(forKey: Self.languageKey) ?? ""
        ) ?? .systemDefault
        self.appearance = AppAppearance(
            rawValue: defaults.string(forKey: Self.appearanceKey) ?? ""
        ) ?? .system
        self.accessibilityModeEnabled = defaults.bool(forKey: Self.accessibilityModeKey)
    }

    func validatePersistedSettings() throws {
        try PersistedSettings.validateEnum(AppLanguage.self, in: defaults, key: Self.languageKey)
        try PersistedSettings.validateEnum(AppAppearance.self, in: defaults, key: Self.appearanceKey)
    }

    func resetInvalidSettings() {
        do { try PersistedSettings.validateEnum(AppLanguage.self, in: defaults, key: Self.languageKey) }
        catch { language = .systemDefault }
        do { try PersistedSettings.validateEnum(AppAppearance.self, in: defaults, key: Self.appearanceKey) }
        catch { appearance = .system }
    }

    // CLI SwiftPM's accessor searches beside the executable, which does not
    // match a signed macOS app's Contents/Resources layout. Resolve the installed
    // app explicitly; retain SwiftPM's accessor for command-line unit tests.
    private static let resourceBundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "Launcher27B_Launcher27B", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing packaged localization resources")
            }
            return bundle
        }
        return Bundle.module
    }()

    func localized(_ key: String) -> String {
        // SwiftPM may normalize localization directory names to lowercase.
        guard let localization = Self.resourceBundle.localizations.first(where: {
            $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
        }), let resourceURL = Self.resourceBundle.resourceURL,
        let localizationBundle = Bundle(url: resourceURL
            .appendingPathComponent("\(localization).lproj")) else {
            preconditionFailure("Missing localization bundle: \(language.rawValue)")
        }

        return localizationBundle.localizedString(
            forKey: key,
            value: "[Missing translation: \(key)]",
            table: "Localizable"
        )
    }

    func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(key),
            locale: language.locale,
            arguments: arguments
        )
    }
}
