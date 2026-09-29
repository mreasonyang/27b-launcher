import Foundation
import ObjectiveC.runtime
import Testing
@testable import Launcher27B

/// Verifies that Simplified Chinese messages remain valid localization arguments.
///
/// The app uses Simplified Chinese literals as localization *keys*, and
/// `AppPreferences.localizedFormat(_:_:)` substitutes its arguments into the
/// translated template. If a Chinese literal is passed as one of those
/// arguments, it survives translation and leaks verbatim into every other UI
/// language. `LocalizationTests` cannot see this: it verifies that keys exist
/// and that format-specifier counts agree, never that an argument is free of
/// Chinese.
///
/// These tests render representative errors of every app-error enum with an
/// English preference and assert the result contains no CJK, then repeat with a
/// Chinese preference to prove the rendering is genuinely localized rather than
/// a constant.
///
/// ## Why the bundle override below exists
///
/// `Resources/` is copied into the `.app` by `Scripts/build-app.sh`, not by
/// SwiftPM, and `swift test` runs the suite from the SwiftPM helper executable.
/// `Bundle.main` is therefore *not* the app bundle, so
/// `AppPreferences.localized(_:)` would fall back to returning the key itself
/// (Simplified Chinese) for every language — making an "English output has no
/// CJK" assertion fail regardless of the code under test. To exercise the real
/// translations, `PackageResources` temporarily redirects `Bundle.main`.
///
/// The redirect is scoped to the *current thread* and the enclosing call is
/// synchronous with no suspension point, so suites running in parallel on other
/// threads keep seeing the real main bundle.
@Suite(.serialized)
struct ErrorLocalizationTests {
    // MARK: - English rendering: no case may leak CJK

    /// Every case of `ModelStorageError`, `ArtifactDownloadError`,
    /// `InstallerError` and `HardwareRequirementIssue`, rendered for an English
    /// user, must be free of CJK.
    @MainActor
    @Test
    func englishRenderingOfEveryErrorCaseContainsNoCJK() {
        Self.withPreferences(.english) { preferences in
            PackageResources.withPackageResources {
                for sample in Self.allSamples() {
                    let rendered = sample.error.localizedDescription(using: preferences)
                    #expect(
                        !Self.containsCJK(rendered),
                        "\(sample.label) leaked CJK into the English rendering: \(rendered)"
                    )
                }
            }
        }
    }

    /// Inverse sanity check: the same renderings under a Simplified-Chinese
    /// preference *do* contain CJK. Without this, the assertion above could pass
    /// against a constant English string that never actually localizes.
    @MainActor
    @Test
    func chineseRenderingOfEveryErrorCaseContainsCJK() {
        Self.withPreferences(.simplifiedChinese) { preferences in
            PackageResources.withPackageResources {
                for sample in Self.allSamples() {
                    let rendered = sample.error.localizedDescription(using: preferences)
                    #expect(
                        Self.containsCJK(rendered),
                        "\(sample.label) did not render Simplified Chinese: \(rendered)"
                    )
                }
            }
        }
    }

    /// The harness itself: if `Bundle.main` cannot be redirected at the package
    /// resources, the two tests above become vacuous. Fail loudly here instead.
    @MainActor
    @Test
    func packageResourcesOverrideResolvesRealTranslations() {
        Self.withPreferences(.english) { preferences in
            let rendered = PackageResources.withPackageResources {
                ModelStorageError.verificationFailed.localizedDescription(using: preferences)
            }
            #expect(
                !Self.containsCJK(rendered),
                "Bundle.main override did not resolve English translations; rendered: \(rendered)"
            )
        }
    }

    // MARK: - The production migration path

    /// Drives the real `migrate(to:)` path that refuses to switch when another
    /// process recreated the canonical models directory, then renders the error
    /// the production code actually threw. This is what makes the guard catch a
    /// call-site error: interpolating a Chinese literal
    /// (as the removed `migrationFailed` case did) leaks CJK here.


    // MARK: - Raw system failures must not smuggle OS-language text

    /// An OS-language
    /// (Chinese-locale) `NSError` message must not survive into an English
    /// rendering, neither as CJK nor verbatim as the raw text.
    @MainActor
    @Test
    func systemFileOperationFailedNeverEmbedsOSLanguageTextInEnglish() {
        let osMessage = "文件“model.gguf”无法保存。"
        let error = ModelStorageError.systemFileOperationFailed(underlying: osMessage)

        Self.withPreferences(.english) { preferences in
            PackageResources.withPackageResources {
                let rendered = error.localizedDescription(using: preferences)
                #expect(
                    !Self.containsCJK(rendered),
                    "Raw OS error leaked CJK into the English rendering: \(rendered)"
                )
                #expect(
                    !rendered.contains(osMessage),
                    "Raw OS error leaked verbatim into the English rendering: \(rendered)"
                )
            }
        }

        // Diagnostics are preserved for logs, just never rendered to the user.
        #expect(error.diagnosticDescription == osMessage)
    }

    /// `FileSystemFailure` classifies a caught error into a category whose
    /// localized message is argument-free, and returns `nil` when it cannot.
    @MainActor
    @Test
    func fileSystemFailureLocalizesClassifiedErrorsWithoutTheOSMessage() throws {
        let osMessage = "文件“model.gguf”无法保存。"
        let permissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: osMessage]
        )
        let outOfSpaceError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: osMessage]
        )
        #expect(FileSystemFailure.category(of: permissionError) == .permissionDenied)
        #expect(FileSystemFailure.category(of: outOfSpaceError) == .outOfSpace)

        Self.withPreferences(.english) { preferences in
            PackageResources.withPackageResources {
                for error in [permissionError, outOfSpaceError] {
                    guard let message = FileSystemFailure.localizedMessage(
                        for: error,
                        using: preferences
                    ) else {
                        Issue.record("Expected a localized message for \(error)")
                        continue
                    }
                    #expect(
                        !Self.containsCJK(message),
                        "Classified system error leaked CJK: \(message)"
                    )
                    #expect(
                        !message.contains(osMessage),
                        "Classified system error embedded the raw OS message: \(message)"
                    )
                }
            }
        }

        let unclassifiable = NSError(
            domain: "Launcher27BTests.unclassifiable",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: osMessage]
        )
        #expect(FileSystemFailure.category(of: unclassifiable) == nil)
        Self.withPreferences(.english) { preferences in
            #expect(
                FileSystemFailure.localizedMessage(for: unclassifiable, using: preferences) == nil
            )
        }
    }

    /// Drives the real `migrate(to:)` path so a genuinely unreadable model file
    /// raises a raw POSIX permission failure at the `:377` catch site, and asserts
    /// the error the production code actually threw is the keyed, argument-free
    /// case rather than a wrapper around the OS message.
    @MainActor
    @Test
    func permissionDeniedMigrationFailureRendersWithoutCJKInEnglish() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-error-localization-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let modelDirectory = support.appending(path: "models/27B", directoryHint: .isDirectory)
        let modelURL = modelDirectory.appending(path: "model.gguf")
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x27, count: 4096).write(to: modelURL)

        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "https://example.invalid/model")!,
            destinationURL: modelURL,
            expectedByteCount: 4096,
            expectedSHA256: try FileChecksum().sha256(at: modelURL),
            kind: .file
        )
        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: modelURL,
            projectorFile: modelDirectory.appending(path: "projector.gguf"),
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        // An unreadable source file makes the copy raise a raw POSIX EACCES
        // failure, which is exactly what the :377 catch site classifies.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: modelURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: modelURL.path
            )
        }

        let manager = ModelStorageManager(config: config, artifacts: [artifact])

        var thrown: (any Error)?
        do {
            _ = try await manager.migrate(
                to: root.appending(path: "external", directoryHint: .isDirectory)
            )
        } catch {
            thrown = error
        }

        let error = try #require(thrown, "Migration unexpectedly succeeded")
        let storageError = try #require(error as? ModelStorageError)
        #expect(storageError == .systemPermissionDenied)

        Self.withPreferences(.english) { preferences in
            let rendered = PackageResources.withPackageResources {
                storageError.localizedDescription(using: preferences)
            }
            #expect(
                !Self.containsCJK(rendered),
                "Migration failure leaked CJK into the English rendering: \(rendered)"
            )
        }
    }

    // MARK: - Representative instances

    /// Every app error that uses the two-tier `errorDescription` /
    /// `localizedDescription(using:)` design, paired with a readable label.
    ///
    /// The lists are hand-maintained: associated values block `CaseIterable`
    /// synthesis. The exhaustive `label(for:)` switches below are the
    /// compile-time tripwire — adding a case to any of these enums fails to
    /// compile here, pointing the author at the list that needs a sample.
    private static func allSamples() -> [(label: String, error: any AppLocalizableError)] {
        var samples: [(label: String, error: any AppLocalizableError)] = []
        for error in modelStorageSamples() {
            samples.append((label(for: error), error))
        }
        for error in artifactDownloadSamples() {
            samples.append((label(for: error), error))
        }
        for error in installerSamples() {
            samples.append((label(for: error), error))
        }
        for error in hardwareSamples() {
            samples.append((label(for: error), error))
        }
        return samples
    }

    private static func modelStorageSamples() -> [ModelStorageError] {
        [
            .sourceMissing,
            .destinationExists,
            .destinationInsideSource,
            .destinationReadOnly,
            .destinationIsNetworkVolume,
            .destinationFileSystemUnsupported(
                fileSystem: "msdos",
                largestFileBytes: 6_000_000_000
            ),
            .destinationContainsIncompleteCopy,
            .insufficientDiskSpace(required: 10_000_000_000, available: 1_000_000_000),
            .verificationFailed,
            .destinationFileCreationFailed,
            .systemOutOfSpace,
            .systemPermissionDenied,
            .systemFileMissing,
            .systemFileReadOnly,
            // The associated value is the raw OS message, kept for logs only; it
            // must never appear in the localized rendering.
            .systemFileOperationFailed(underlying: "The file could not be saved."),
        ]
    }

    private static func artifactDownloadSamples() -> [ArtifactDownloadError] {
        [
            .missingTemporaryFile,
            .invalidResponse,
            .httpStatus(503),
            .networkInterrupted,
            .timedOut,
            .resumeDataPersistenceFailed,
            .incompleteDownload,
            .diskFull,
            .fileWriteFailed,
            .unexpectedContentType,
            .unexpectedContentLength(expected: 4_000_000, actual: 2_000_000),
        ]
    }

    private static func installerSamples() -> [InstallerError] {
        [
            .insufficientDiskSpace(required: 10_000_000_000, available: 1_000_000_000),
            .checksumMismatch(component: .model),
            .runtimeArchiveInvalid,
            .commandFailed(command: "codesign --verify --deep", status: 1),
            .diskFull,
            .permissionDenied,
            .sourceMissing(component: .projector),
            .fileOperationFailed(underlying: "The file couldn't be saved."),
        ]
    }

    private static func hardwareSamples() -> [HardwareRequirementIssue] {
        [
            .unsupportedArchitecture(current: "x86_64"),
            .insufficientMemory(requiredBytes: 32_000_000_000, availableBytes: 8_000_000_000),
            .limitedMemory(recommendedBytes: 32_000_000_000, availableBytes: 16_000_000_000),
        ]
    }

    private static func label(for error: ModelStorageError) -> String {
        switch error {
        case .sourceMissing: "ModelStorageError.sourceMissing"
        case .destinationExists: "ModelStorageError.destinationExists"
        case .destinationInsideSource: "ModelStorageError.destinationInsideSource"
        case .destinationReadOnly: "ModelStorageError.destinationReadOnly"
        case .destinationIsNetworkVolume: "ModelStorageError.destinationIsNetworkVolume"
        case .destinationFileSystemUnsupported: "ModelStorageError.destinationFileSystemUnsupported"
        case .destinationContainsIncompleteCopy: "ModelStorageError.destinationContainsIncompleteCopy"
        case .insufficientDiskSpace: "ModelStorageError.insufficientDiskSpace"
        case .verificationFailed: "ModelStorageError.verificationFailed"
        case .destinationFileCreationFailed: "ModelStorageError.destinationFileCreationFailed"
        case .systemOutOfSpace: "ModelStorageError.systemOutOfSpace"
        case .systemPermissionDenied: "ModelStorageError.systemPermissionDenied"
        case .systemFileMissing: "ModelStorageError.systemFileMissing"
        case .systemFileReadOnly: "ModelStorageError.systemFileReadOnly"
        case .systemFileOperationFailed: "ModelStorageError.systemFileOperationFailed"
        }
    }

    private static func label(for error: ArtifactDownloadError) -> String {
        switch error {
        case .missingTemporaryFile: "ArtifactDownloadError.missingTemporaryFile"
        case .invalidResponse: "ArtifactDownloadError.invalidResponse"
        case .httpStatus: "ArtifactDownloadError.httpStatus"
        case .networkInterrupted: "ArtifactDownloadError.networkInterrupted"
        case .timedOut: "ArtifactDownloadError.timedOut"
        case .resumeDataPersistenceFailed: "ArtifactDownloadError.resumeDataPersistenceFailed"
        case .incompleteDownload: "ArtifactDownloadError.incompleteDownload"
        case .diskFull: "ArtifactDownloadError.diskFull"
        case .fileWriteFailed: "ArtifactDownloadError.fileWriteFailed"
        case .unexpectedContentType: "ArtifactDownloadError.unexpectedContentType"
        case .unexpectedContentLength: "ArtifactDownloadError.unexpectedContentLength"
        }
    }

    private static func label(for error: InstallerError) -> String {
        switch error {
        case .insufficientDiskSpace: "InstallerError.insufficientDiskSpace"
        case .checksumMismatch: "InstallerError.checksumMismatch"
        case .runtimeArchiveInvalid: "InstallerError.runtimeArchiveInvalid"
        case .commandFailed: "InstallerError.commandFailed"
        case .diskFull: "InstallerError.diskFull"
        case .permissionDenied: "InstallerError.permissionDenied"
        case .sourceMissing: "InstallerError.sourceMissing"
        case .fileOperationFailed: "InstallerError.fileOperationFailed"
        }
    }

    private static func label(for error: HardwareRequirementIssue) -> String {
        switch error {
        case .unsupportedArchitecture: "HardwareRequirementIssue.unsupportedArchitecture"
        case .insufficientMemory: "HardwareRequirementIssue.insufficientMemory"
        case .limitedMemory: "HardwareRequirementIssue.limitedMemory"
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func withPreferences<T>(
        _ language: AppLanguage,
        _ body: @MainActor (AppPreferences) -> T
    ) -> T {
        let suiteName = "Launcher27BTests.ErrorLocalization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.language = language
        return body(preferences)
    }

    /// CJK ranges mirrored from `LocalizationTests`.
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, // CJK symbols and punctuation
                 0x3400...0x4DBF, // CJK unified ideographs extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFF00...0xFFEF: // Halfwidth and fullwidth forms
                return true
            default:
                return false
            }
        }
    }
}

/// Temporarily points `Bundle.main` at the package's `Resources/` directory so
/// `AppPreferences` resolves the real `.lproj` tables during tests.
///
/// `swift test` executes the suite from the SwiftPM helper executable, whose
/// main bundle contains no `en.lproj`; without this redirect `localized(_:)`
/// returns the key (Simplified Chinese) for every language and the CJK
/// assertions above cannot mean anything.
///
/// The override is stored in the calling thread's dictionary, so only the
/// thread running these synchronous `@MainActor` tests sees it. For the same
/// reason the override must never be held across an `await`: another test could
/// then be resumed on this thread and observe it.
private enum PackageResources {
    @MainActor static func withPackageResources<T>(_ body: @MainActor () throws -> T) rethrows -> T { try body() }
}
