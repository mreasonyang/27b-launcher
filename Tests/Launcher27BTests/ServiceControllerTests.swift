import Foundation
import Testing
@testable import Launcher27B

@Suite
struct ServiceControllerTests {
    @Test
    func recognizesTaskAndURLSessionCancellation() {
        #expect(ServiceController.isInstallationCancellation(CancellationError()))
        #expect(ServiceController.isInstallationCancellation(URLError(.cancelled)))
        #expect(!ServiceController.isInstallationCancellation(URLError(.timedOut)))
    }

    @Test
    func migrationRequiresAConfirmedStoppedService() {
        #expect(ServiceController.canMigrateAfterStopping(.stopped))
        #expect(!ServiceController.canMigrateAfterStopping(.running))
        #expect(!ServiceController.canMigrateAfterStopping(.external))
        #expect(!ServiceController.canMigrateAfterStopping(.stopping))
    }

    @Test
    @MainActor
    func revealLogsOpensTheLogDirectoryItself() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-log-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: root.path],
            homeDirectory: root
        )
        var openedURL: URL?
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            openDirectory: { url in
                openedURL = url
                return true
            }
        )

        controller.revealLogs()

        #expect(openedURL == config.logDirectory)
        #expect(FileManager.default.fileExists(atPath: config.logDirectory.path))
    }

    @Test
    @MainActor
    func reportsAlreadyInstalledRuntimeAsReused() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-reuse-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: root.path],
            homeDirectory: root
        )
        let runtime = config.serverBinary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: config.serverBinary.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: config.serverBinary.path
        )
        #expect(
            FileManager.default.createFile(
                atPath: runtime.appending(path: "libllama-server-impl.dylib").path,
                contents: Data()
            )
        )
        try "\(InstallationCatalog.runtimeRelease)\n".write(
            to: runtime.appending(path: ".llama_release"),
            atomically: true,
            encoding: .utf8
        )

        let controller = ServiceController(config: config, requiresInstanceLock: false, preferences: TestPreferences.chinese())
        controller.recheckInstallation()

        #expect(controller.reusedArtifacts.map(\.component) == [.runtime])
        #expect(controller.missingArtifacts.map(\.component) == [.model, .projector, .adapter])
    }

    @Test
    @MainActor
    func unavailableConfiguredModelLocationDoesNotOfferRedownload() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-unavailable-model-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: root.path],
            homeDirectory: root
        )
        try FileManager.default.createDirectory(
            at: config.modelsDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unavailableTarget = root.appending(path: "missing-model-location")
        try config.setModelsDirectory(unavailableTarget)

        let controller = ServiceController(config: config, requiresInstanceLock: false, preferences: TestPreferences.chinese())
        controller.recheckInstallation()

        #expect(controller.installationStatus == .failed)
        #expect(controller.modelStorageConfigurationUnavailable)
        #expect(controller.missingArtifacts.isEmpty)
        #expect(controller.installationError?.contains("模型位置不可用") == true)
    }
}
