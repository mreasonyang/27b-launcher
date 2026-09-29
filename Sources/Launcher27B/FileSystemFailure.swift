import Foundation

/// Classifies raw Foundation/POSIX file-system failures so callers can replace
/// English `NSError` text with actionable, localized messages.
enum FileSystemFailure {
    /// A classifiable system failure. Every category maps onto a localization key
    /// that already exists in all languages, so callers can render an
    /// argument-free, translated message instead of interpolating the
    /// OS-language `NSError` text into a localized sentence.
    enum Category: Sendable, Equatable {
        case outOfSpace
        case permissionDenied
        case missingSource
        case readOnly

        /// The user-facing key for this category. These are the same keys
        /// `ServiceController` uses for its raw-system-error mapping; they are
        /// deliberately reused rather than duplicated as new strings.
        var localizationKey: String {
            switch self {
            case .outOfSpace: "磁盘空间不足，操作未完成；请清理磁盘后重试。"
            case .permissionDenied: "没有访问该位置的权限；请检查文件权限后重试。"
            case .missingSource: "找不到所需的文件或文件夹；它可能已被移动或删除。"
            case .readOnly: "目标位置为只读，无法写入。"
            }
        }
    }

    /// `NSFileWriteOutOfSpaceError`, POSIX `ENOSPC`, or the URL loading system's
    /// "cannot write to file" (-3000) all mean the same thing: the volume is full.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError):
            return true
        case (NSPOSIXErrorDomain, Int(ENOSPC)):
            return true
        case (NSURLErrorDomain, NSURLErrorCannotWriteToFile):
            return true
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOutOfSpace(underlying)
        }
        return false
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSCocoaErrorDomain, NSFileReadNoPermissionError):
            return true
        case (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return true
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    static func isMissingSource(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            return true
        case (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingSource(underlying)
        }
        return false
    }

    static func isReadOnly(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError):
            return true
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isReadOnly(underlying)
        }
        return false
    }

    /// Classifies `error` into a category that has a ready-made localized message.
    /// Returns `nil` when no category applies, so callers fall back to a generic
    /// (equally argument-free) message.
    static func category(of error: Error) -> Category? {
        if isOutOfSpace(error) { return .outOfSpace }
        if isPermissionDenied(error) { return .permissionDenied }
        if isMissingSource(error) { return .missingSource }
        if isReadOnly(error) { return .readOnly }
        return nil
    }

    /// Localized, argument-free message for a caught system error, or `nil` when
    /// the error cannot be classified. Never interpolates the raw error text, so
    /// an OS-language `NSError` string can never leak into a translated sentence.
    @MainActor
    static func localizedMessage(for error: Error, using preferences: AppPreferences) -> String? {
        guard let category = category(of: error) else { return nil }
        return preferences.localized(category.localizationKey)
    }
}
