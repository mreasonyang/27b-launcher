import Foundation
import Testing
@testable import Launcher27B

@Suite(.serialized)
struct ModelStorageManagerTests {


    @Test
    func rejectsDestinationSymlinkedInsideCurrentModels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-model-symlink-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: support.path],
            homeDirectory: root
        )
        try FileManager.default.createDirectory(
            at: config.modelsDirectory.appending(path: "nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let alias = root.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: config.modelsDirectory.appending(path: "nested")
        )
        let manager = ModelStorageManager(config: config, artifacts: [])

        await #expect(throws: ModelStorageError.destinationInsideSource) {
            try await manager.migrate(to: alias)
        }
    }

    private actor ProgressObservation {
        private(set) var phases: [ModelStorageMigrationPhase] = []

        func record(_ progress: ModelStorageMigrationProgress) {
            phases.append(progress.phase)
        }
    }

    private actor ProgressGate {
        private var reached = false
        private var continuation: CheckedContinuation<Void, Never>?

        func reach() {
            reached = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            if reached { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    @Test
    func migratesVerifiesAndRecordsExplicitLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-storage-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let modelDirectory = support.appending(path: "models/27B", directoryHint: .isDirectory)
        let modelURL = modelDirectory.appending(path: "model.gguf")
        let projectorURL = modelDirectory.appending(path: "projector.gguf")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x27, count: 4096).write(to: modelURL)
        try Data(repeating: 0x2B, count: 2048).write(to: projectorURL)

        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: modelURL,
            projectorFile: projectorURL,
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        let checksum = FileChecksum()
        let artifacts = [
            InstallationArtifact(
                component: .model,
                downloadURL: URL(string: "https://example.invalid/model")!,
                destinationURL: modelURL,
                expectedByteCount: 4096,
                expectedSHA256: try checksum.sha256(at: modelURL),
                kind: .file
            ),
            InstallationArtifact(
                component: .projector,
                downloadURL: URL(string: "https://example.invalid/projector")!,
                destinationURL: projectorURL,
                expectedByteCount: 2048,
                expectedSHA256: try checksum.sha256(at: projectorURL),
                kind: .file
            ),
        ]
        let destinationParent = root.appending(path: "external", directoryHint: .isDirectory)
        let manager = ModelStorageManager(config: config, artifacts: artifacts)
        let observation = ProgressObservation()

        let result = try await manager.migrate(to: destinationParent) { progress in
            await observation.record(progress)
        }

        let canonical = config.modelsDirectory
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect(result.url.path == destinationParent.appending(path: "Bonsai2 Models").path)
        #expect(result.isAvailable)
        #expect(result.byteCount > 0)
        #expect(try checksum.sha256(at: config.modelFile) == artifacts[0].expectedSHA256)
        #expect(try checksum.sha256(at: config.projectorFile) == artifacts[1].expectedSHA256)

        let refreshed = try await manager.snapshot()
        #expect(refreshed.url.path == result.url.path)
        #expect(refreshed.isAvailable)
        let phases = await observation.phases
        #expect(phases.contains(.copying))
        #expect(phases.contains(.verifying))
        #expect(phases.contains(.switching))
    }

    @Test
    func failedVerificationKeepsOriginalModelsAndRemovesStagingCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-storage-rollback-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let modelURL = support.appending(path: "models/27B/model.gguf")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x27, count: 1024).write(to: modelURL)
        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: modelURL,
            projectorFile: support.appending(path: "models/27B/projector.gguf"),
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "https://example.invalid/model")!,
            destinationURL: modelURL,
            expectedByteCount: 1024,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )
        let destinationParent = root.appending(path: "external", directoryHint: .isDirectory)
        let manager = ModelStorageManager(config: config, artifacts: [artifact])

        do {
            _ = try await manager.migrate(to: destinationParent)
            Issue.record("Migration unexpectedly accepted a bad checksum")
        } catch let error as ModelStorageError {
            guard case .verificationFailed = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationParent.appending(path: "Bonsai2 Models").path
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: config.modelsDirectory.path
        )
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
    }

    @Test
    func cancellationDuringMigrationRemovesStagingAndKeepsOriginalModels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-storage-cancel-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let modelURL = support.appending(path: "models/27B/model.gguf")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x27, count: 4 * 1024 * 1024).write(to: modelURL)
        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: modelURL,
            projectorFile: support.appending(path: "models/27B/projector.gguf"),
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "https://example.invalid/model")!,
            destinationURL: modelURL,
            expectedByteCount: 4 * 1024 * 1024,
            expectedSHA256: try FileChecksum().sha256(at: modelURL),
            kind: .file
        )
        let destinationParent = root.appending(path: "external", directoryHint: .isDirectory)
        let manager = ModelStorageManager(config: config, artifacts: [artifact])
        let gate = ProgressGate()

        let migrationTask = Task {
            try await manager.migrate(to: destinationParent) { progress in
                if progress.phase == .copying, progress.stageCompletedBytes > 0 {
                    await gate.reach()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        await gate.wait()
        migrationTask.cancel()

        do {
            _ = try await migrationTask.value
            Issue.record("Migration unexpectedly completed after cancellation")
        } catch is CancellationError {
            // Expected: the original path remains authoritative.
        }

        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationParent.appending(path: "Bonsai2 Models").path
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: config.modelsDirectory.path
        )
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
    }
}
