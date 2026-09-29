import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var nativeName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .spanish: "Español"
        }
    }

    static var systemDefault: AppLanguage {
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("zh-Hant") || identifier.hasPrefix("zh-TW") || identifier.hasPrefix("zh-HK") {
                return .traditionalChinese
            }
            if identifier.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if identifier.hasPrefix("es") {
                return .spanish
            }
            if identifier.hasPrefix("en") {
                return .english
            }
        }
        return .english
    }
}
