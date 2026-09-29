protocol AppLocalizableError {
    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String
}
