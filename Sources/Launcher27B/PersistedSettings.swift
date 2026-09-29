import Foundation

/// Absence selects a product default. Stored values must match the current schema.
enum PersistedSettings {
    static func validateEnum<T: RawRepresentable>(_ type: T.Type, in defaults: UserDefaults, key: String) throws where T.RawValue == String {
        guard let value = defaults.object(forKey: key) else { return }
        guard let raw = value as? String, T(rawValue: raw) != nil else { throw invalid(key) }
    }

    static func invalid(_ key: String) -> InvalidSavedSetting { InvalidSavedSetting(key: key) }
}

struct InvalidSavedSetting: Error, AppLocalizableError {
    let key: String
    @MainActor func localizedDescription(using preferences: AppPreferences) -> String {
        preferences.localizedFormat("保存的设置 %@ 无效，请在设置中重置无效项。", key)
    }
}
