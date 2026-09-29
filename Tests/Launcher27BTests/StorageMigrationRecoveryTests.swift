import Foundation
import Testing
@testable import Launcher27B

@Suite(.serialized)
struct StorageMigrationRecoveryTests {
    @Test
    func destinationProbeFailsClosedWhenTheVolumeCannotBeInspected() throws {
        // A non-file URL yields resource values whose volume keys are nil. Measured on
        // macOS: `volumeIsLocal` and `volumeIsReadOnly` are both nil, with no throw.
        let nonFile = URL(string: "https://example.invalid/models")!
        #expect(ModelStorageDestinationProbe.descriptor(at: nonFile) == nil)

        // A path the process cannot inspect yields no resource values at all.
        let missing = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-missing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        #expect(ModelStorageDestinationProbe.descriptor(at: missing) == nil)
    }

    @Test
    func failedStagingRestoreKeepsThePreviousModelFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-installer-restore-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: support.path],
            homeDirectory: root
        )
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "https://example.invalid/model")!,
            destinationURL: config.modelFile,
            expectedByteCount: 4096,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )

        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previousContents = Data(repeating: 0x3C, count: 4096)
        let backupURL = BonsaiInstaller.backupURL(for: config.modelFile)
        try previousContents.write(to: backupURL)

        // Force the restore to fail: a self-referential symlink occupies the
        // destination path. `fileExists` follows links and so reports the path as free,
        // while `moveItem` refuses because an entry is already there.
        try FileManager.default.createSymbolicLink(
            atPath: config.modelFile.path,
            withDestinationPath: config.modelFile.path
        )
        #expect(!FileManager.default.fileExists(atPath: config.modelFile.path))

        let installer = BonsaiInstaller(config: config)
        await #expect(throws: (any Error).self) { try await installer.sweepStaleStagingEntries(for: [artifact]) }

        #expect(
            FileManager.default.fileExists(atPath: backupURL.path),
            "a failed restore must not be followed by deleting the only remaining copy"
        )
        #expect(try Data(contentsOf: backupURL) == previousContents)
    }
}
