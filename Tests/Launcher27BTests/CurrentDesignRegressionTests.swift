import Darwin
import Foundation
import Testing
@testable import Launcher27B

@Suite(.serialized)
struct CurrentDesignRegressionTests {
    private struct Fixture {
        let root: URL
        let config: LauncherConfig
        let artifacts: [InstallationArtifact]
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "27b-current-" + UUID().uuidString)
        let config = LauncherConfig.makeLocalInstallation(environment: [LauncherConfig.supportDirectoryOverrideKey: root.appending(path: "support").path], homeDirectory: root)
        try FileManager.default.createDirectory(at: config.modelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pairs: [(InstallationComponent, URL, Data)] = [(.model, config.modelFile, Data(repeating: 27, count: 4096)), (.projector, config.projectorFile, Data(repeating: 28, count: 2048))]
        let artifacts = try pairs.map { component, url, bytes in
            try bytes.write(to: url)
            return InstallationArtifact(component: component, downloadURL: URL(string: "https://example.invalid/model")!, destinationURL: url, expectedByteCount: Int64(bytes.count), expectedSHA256: try FileChecksum().sha256(at: url), kind: .file)
        }
        return Fixture(root: root, config: config, artifacts: artifacts)
    }
    private func manager(_ f: Fixture, free: Int64 = 2_000_000_000) -> ModelStorageManager {
        ModelStorageManager(config: f.config, artifacts: f.artifacts, volumeDescriptorProvider: { _ in
            ModelStorageDestinationDescriptor(fileSystemName: "apfs", isLocal: true, isReadOnly: false, supportsFilesAbove4GB: true, availableBytes: free)
        })
    }

    @Test func explicitLocationSurvivesRelaunchAndTwoMoves() async throws {
        let f = try fixture(); defer { f.clean() }
        let original = f.config.modelsDirectory
        let first = try await manager(f).migrate(to: f.root.appending(path: "one"))
        #expect(f.config.modelsDirectory.path == first.url.path)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let reread = LauncherConfig.makeLocalInstallation(environment: [LauncherConfig.supportDirectoryOverrideKey: f.config.supportDirectory.path], homeDirectory: f.root)
        #expect(reread.modelsDirectory.path == first.url.path)
        let second = try await manager(f).migrate(to: f.root.appending(path: "two"))
        #expect(f.config.modelsDirectory.path == second.url.path)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(try FileChecksum().sha256(at: reread.modelFile) == f.artifacts[0].expectedSHA256)
        let attributes = try FileManager.default.attributesOfItem(atPath: second.url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
    }

    @Test func existingNonemptySymlinkDestinationNeedsOnlyHeadroom() async throws {
        let f = try fixture(); defer { f.clean() }
        let parent = f.root.appending(path: "external")
        let copy = f.root.appending(path: "verified-copy")
        try FileManager.default.copyItem(at: f.config.modelsDirectory, to: copy)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent.appending(path: "Bonsai2 Models"), withDestinationURL: copy)
        let result = try await manager(f, free: 536_870_912).migrate(to: parent)
        #expect(result.url == copy.resolvingSymlinksInPath())
        #expect(try FileChecksum().sha256(at: f.config.modelFile) == f.artifacts[0].expectedSHA256)
    }

    @Test func copyingStillRequiresSpaceForAllBytes() async throws {
        let f = try fixture(); defer { f.clean() }
        await #expect(throws: ModelStorageError.self) {
            try await manager(f, free: 536_870_912).migrate(to: f.root.appending(path: "external"))
        }
        #expect(try !f.config.hasCustomModelLocation)
        #expect(try FileChecksum().sha256(at: f.config.modelFile) == f.artifacts[0].expectedSHA256)
    }

    @Test func sameSizeBadDestinationIsNeverSelectedOrDeleted() async throws {
        let f = try fixture(); defer { f.clean() }
        let parent = f.root.appending(path: "external")
        let copy = parent.appending(path: "Bonsai2 Models")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.config.modelsDirectory, to: copy)
        try Data(repeating: 0, count: 4096).write(to: copy.appending(path: "27B/" + f.config.modelFile.lastPathComponent))
        await #expect(throws: ModelStorageError.destinationContainsIncompleteCopy) { try await manager(f).migrate(to: parent) }
        #expect(try !f.config.hasCustomModelLocation)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try FileChecksum().sha256(at: f.config.modelFile) == f.artifacts[0].expectedSHA256)
    }

    @Test func equalSizedDifferentExtraFilesCannotAuthorizeSourceDeletion() async throws {
        let f = try fixture(); defer { f.clean() }
        let source = f.config.modelsDirectory
        try Data("notes".utf8).write(to: source.appending(path: "notes.txt"))
        let parent = f.root.appending(path: "external")
        let destination = parent.appending(path: "Bonsai2 Models")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.moveItem(at: destination.appending(path: "notes.txt"), to: destination.appending(path: "different.txt"))
        await #expect(throws: ModelStorageError.destinationExists) { try await manager(f).migrate(to: parent) }
        #expect(try Data(contentsOf: source.appending(path: "notes.txt")) == Data("notes".utf8))
        try FileManager.default.moveItem(at: destination.appending(path: "different.txt"), to: destination.appending(path: "notes.txt"))
        try Data("wrong".utf8).write(to: destination.appending(path: "notes.txt"))
        await #expect(throws: ModelStorageError.verificationFailed) { try await manager(f).migrate(to: parent) }
        #expect(try Data(contentsOf: source.appending(path: "notes.txt")) == Data("notes".utf8))
    }

    @Test func changedSourceDuringCopyIsPreserved() async throws {
        let f = try fixture(); defer { f.clean() }
        let source = f.config.modelsDirectory
        let notes = source.appending(path: "notes.txt")
        try Data("original".utf8).write(to: notes)
        await #expect(throws: ModelStorageError.verificationFailed) {
            try await manager(f).migrate(to: f.root.appending(path: "external")) { progress in
                if progress.phase == .verifying, progress.stageCompletedBytes > 0 {
                    try? Data("changed-content".utf8).write(to: notes)
                }
            }
        }
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(try !f.config.hasCustomModelLocation)
    }

    @Test func sourceRewriteWithRestoredSizeAndMtimeStillPreventsDeletion() async throws {
        let f = try fixture(); defer { f.clean() }
        let model = f.config.modelFile
        await #expect(throws: ModelStorageError.verificationFailed) {
            try await manager(f).migrate(to: f.root.appending(path: "external")) { progress in
                if progress.phase == .verifying, progress.stageCompletedBytes == progress.stageTotalBytes {
                    var original = stat()
                    guard stat(model.path, &original) == 0,
                          let handle = try? FileHandle(forWritingTo: model) else { return }
                    try? handle.write(contentsOf: Data(repeating: 0xCC, count: 4096))
                    try? handle.close()
                    var times = [original.st_atimespec, original.st_mtimespec]
                    _ = times.withUnsafeMutableBufferPointer { utimensat(AT_FDCWD, model.path, $0.baseAddress, 0) }
                }
            }
        }
        #expect(try Data(contentsOf: model) == Data(repeating: 0xCC, count: 4096))
        #expect(try !f.config.hasCustomModelLocation)
    }

    @Test @MainActor func failedStopCannotBeginDamagedComponentRepair() async throws {
        let f = try fixture(); defer { f.clean() }
        let name = "27b-repair-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let process = StubServerProcessManager()
        process.isRunningValue = true
        process.stopError = ServerProcessError.signalFailed(errno: EPERM)
        let controller = ServiceController(config: f.config, requiresInstanceLock: false,
            preferences: TestPreferences.chinese(), processManager: process, defaults: defaults,
            healthProbe: { _ in process.isRunningValue }, loginItemStatus: { .notRegistered },
            installationRunner: { _, _ in Issue.record("Repair must not replace files while the server is running") })
        controller.recordVerification([.model: .checksumMismatch])
        await controller.repairDamagedArtifacts()
        #expect(process.stopCallCount == 1)
        #expect(controller.status == .running)
        #expect(controller.hasDamagedComponents)
        #expect(controller.installationStatus != .installing)
    }

    @Test func productionSignalIdentityRejectsSamePathWithDifferentBirth() throws {
        let f = try fixture(); defer { f.clean() }
        let pid = getpid()
        let executable = try #require(ServerProcessDiscovery.executablePath(of: pid))
        let config = LauncherConfig(serverBinary: URL(filePath: executable), modelFile: f.config.modelFile,
            projectorFile: f.config.projectorFile, ablationAdapterFile: f.config.ablationAdapterFile,
            webUIConfigFile: f.config.webUIConfigFile, chatURL: f.config.chatURL,
            contextSize: "1", reasoningBudget: "1", logDirectory: f.config.logDirectory)
        let birth = try #require(ServerProcessDiscovery.birthIdentity(of: pid))
        #expect(ServerProcessManager.identity(of: pid, config: config, expectedBirth: birth) == .identified)
        #expect(ServerProcessManager.identity(of: pid, config: config, expectedBirth: "reused-pid") == .unrelated)
        #expect(ServerProcessManager.identity(of: pid, config: config, expectedBirth: nil) == .unrelated)
    }

    @Test func corruptLocationNeverUsesDefaultModels() async throws {
        let f = try fixture(); defer { f.clean() }
        try FileManager.default.createDirectory(at: f.config.modelLocationRecord, withIntermediateDirectories: true)
        // Corrupt location configuration must fail before copying or selecting defaults.
        await #expect(throws: (any Error).self) { try await manager(f).migrate(to: f.root.appending(path: "external")) }
        #expect(FileManager.default.fileExists(atPath: f.artifacts[0].destinationURL.path))
    }

    @Test func atomicLocationWriteFailurePreservesVerifiedDestination() async throws {
        let f = try fixture(); defer { f.clean() }
        let source = f.config.modelsDirectory
        let parent = f.root.appending(path: "external")
        await #expect(throws: (any Error).self) {
            try await manager(f).migrate(to: parent) { progress in
                if progress.phase == .verifying, progress.stageCompletedBytes == progress.stageTotalBytes {
                    try? FileManager.default.createDirectory(at: f.config.modelLocationRecord, withIntermediateDirectories: true)
                }
            }
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let destination = parent.appending(path: "Bonsai2 Models/27B/" + f.artifacts[0].destinationURL.lastPathComponent)
        #expect(try FileChecksum().sha256(at: destination) == f.artifacts[0].expectedSHA256)
    }

    @Test func deadCopyJournalIsReclaimedButLiveOwnerIsPreserved() async throws {
        let f = try fixture(); defer { f.clean() }
        let id = UUID()
        let staging = f.root.appending(path: ".Bonsai2 Models.copy-" + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: staging.appending(path: "partial"))
        let journal = f.config.supportDirectory.appending(path: "model-copy.json")
        let live: [String: Any] = ["id": id.uuidString, "ownerPID": getpid(), "ownerBirth": ServerProcessDiscovery.birthIdentity(of: getpid())!, "staging": staging.path]
        try JSONSerialization.data(withJSONObject: live).write(to: journal)
        try await manager(f).recoverInterruptedCopy()
        #expect(FileManager.default.fileExists(atPath: staging.path))
        var dead = live
        dead["ownerBirth"] = "different-process-instance"
        try JSONSerialization.data(withJSONObject: dead).write(to: journal)
        try await manager(f).recoverInterruptedCopy()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(FileManager.default.fileExists(atPath: f.config.modelFile.path))
    }

    @Test func unknownJournalCannotDeleteAnUnrelatedDirectory() async throws {
        let f = try fixture(); defer { f.clean() }
        let other = f.root.appending(path: "personal-files")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let journal: [String: Any] = ["id": UUID().uuidString, "ownerPID": -1, "ownerBirth": "gone", "staging": other.path]
        try JSONSerialization.data(withJSONObject: journal).write(to: f.config.supportDirectory.appending(path: "model-copy.json"))
        await #expect(throws: ModelStorageError.verificationFailed) { try await manager(f).recoverInterruptedCopy() }
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func unknownCheckpointFormatsAreRejected() throws {
        let f = try fixture(); defer { f.clean() }
        let url = f.root.appending(path: "checkpoint")
        try Data("4096\n\"old-etag\"".utf8).write(to: url)
        #expect(throws: (any Error).self) { try DownloadProgressCheckpoint().readResumeMarker(from: url) }
        let marker = DownloadProgressCheckpoint.ResumeMarker(bytes: 4096, validator: "\"current\"")
        try DownloadProgressCheckpoint().writeResumeMarker(marker, to: url)
        #expect(try DownloadProgressCheckpoint().readResumeMarker(from: url) == marker)
    }

    @Test func diskCapacityIsARealNonnegativeMeasurement() throws {
        let f = try fixture(); defer { f.clean() }
        #expect(try DiskCapacity.available(at: f.root) >= 0)
        #expect(throws: (any Error).self) { try DiskCapacity.available(at: f.root.appending(path: "missing")) }
    }

    @Test @MainActor func failedLockNeverAllowsMutations() throws {
        let f = try fixture(); defer { f.clean() }
        try FileManager.default.createDirectory(at: SingleInstanceLock.defaultURL(supportDirectory: f.config.supportDirectory), withIntermediateDirectories: true)
        let controller = ServiceController(config: f.config, preferences: TestPreferences.chinese(), processManager: StubServerProcessManager(), healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        #expect(!controller.isPrimaryInstance)
        controller.acquireSingleInstanceLock()
        #expect(controller.instanceLockState == .unavailable)
        #expect(!controller.isPrimaryInstance)
        #expect(!controller.canStart)
        #expect(controller.presentedError != nil)
    }

    @Test func metricsNeverAttachCredentialsAndPublicTelemetryWorks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialTrapProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = LlamaMetricsClient(session: session)
        let result = try await client.fetch(baseURL: URL(string: "http://127.0.0.1:8080/")!)
        #expect(result.generatedTokens == 1)
    }

    @Test @MainActor func monitoringRefusesRealHTTPRedirects() async throws {
        let f = try fixture(); defer { f.clean() }
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/monitor_redirect_server.py")
        let log = f.root.appending(path: "requests")
        let output = Pipe()
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = [script.path, log.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let text = String(data: output.fileHandleForReading.availableData, encoding: .utf8)
        let port = try #require(text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        await #expect(throws: LlamaMetricsError.requestFailed(302)) { try await LlamaMetricsClient().fetch(baseURL: base) }
        #expect(!(await ServiceController.probeHealth(baseURL: base)))
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests == "/metrics auth=False\n/health auth=False\n")
    }

    @Test @MainActor func foreignHealthyListenerDoesNotPublishTelemetry() async throws {
        let f = try fixture(); defer { f.clean() }
        let process = StubServerProcessManager()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialTrapProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let controller = ServiceController(config: f.config, requiresInstanceLock: false, preferences: TestPreferences.chinese(), processManager: process, metricsClient: LlamaMetricsClient(session: session), healthProbe: { _ in true }, loginItemStatus: { .notRegistered })
        await controller.refresh()
        await controller.refresh()
        #expect(controller.status == .external)
        #expect(controller.tokenUsage == nil)
        #expect(controller.activeLaunchOptions == nil)
    }

    @Test @MainActor func damagedComponentsSurviveRecheckAndRelaunch() throws {
        let f = try fixture(); defer { f.clean() }
        let name = "27b-damage-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = ServiceController(config: f.config, requiresInstanceLock: false, preferences: TestPreferences.chinese(), processManager: StubServerProcessManager(), defaults: defaults, healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        controller.recordVerification([.model: .checksumMismatch])
        controller.recheckInstallation()
        #expect(defaults.stringArray(forKey: "damagedComponents") == ["model"])
        let relaunched = ServiceController(config: f.config, requiresInstanceLock: false, preferences: TestPreferences.chinese(), processManager: StubServerProcessManager(), defaults: defaults, healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        relaunched.recheckInstallation()
        #expect(relaunched.missingArtifacts.contains { $0.component == .model })
        #expect(!relaunched.canStart)
        relaunched.recordVerification([.model: .verified])
        #expect(defaults.stringArray(forKey: "damagedComponents") == [])
    }
    @Test func checkpointWriteFailureCannotLookSuccessful() throws {
        let f = try fixture(); defer { f.clean() }
        let target = f.root.appending(path: "checkpoint")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 10, validator: "\"current\""), to: target)
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func checkpointCannotClaimBytesMissingFromThePartial() throws {
        let f = try fixture(); defer { f.clean() }
        let progress = f.root.appending(path: "checkpoint")
        let partial = f.root.appending(path: "partial")
        try Data(repeating: 1, count: 10).write(to: partial)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 20, validator: "\"current\""), to: progress)
        #expect(throws: (any Error).self) {
            try DownloadProgressCheckpoint().resumeOffset(partialURL: partial, progressDataURL: progress, expectedByteCount: 100)
        }
        #expect(try Data(contentsOf: partial).count == 10)
    }

    @Test func unreadableMetadataNeverBecomesAnEmptyDirectory() throws {
        let f = try fixture(); defer { f.clean() }
        let blocked = f.root.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data([1]).write(to: blocked.appending(path: "file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        #expect(throws: (any Error).self) { try ManagedFileSystem.allocatedBytes(at: blocked) }
        #expect(throws: (any Error).self) { try BonsaiInstaller.volumeRoot(for: blocked.appending(path: "file/child")) }
    }

    @Test func unknownVolumeIdentityCannotSelectCopy() async throws {
        let f = try fixture(); defer { f.clean() }
        let installer = BonsaiInstaller(config: f.config, volumeIdentity: { _ in nil })
        await #expect(throws: (any Error).self) { try await installer.diskSpaceRequirements(for: f.artifacts) }
        #expect(try FileChecksum().sha256(at: f.config.modelFile) == f.artifacts[0].expectedSHA256)
    }

    @Test func malformedLocationCannotHideARetainedSource() async throws {
        let f = try fixture(); defer { f.clean() }
        try Data("broken".utf8).write(to: f.config.modelLocationRecord)
        #expect(throws: (any Error).self) { try f.config.retainedModelSource }
        await #expect(throws: (any Error).self) { try await manager(f).snapshot() }
        #expect(FileManager.default.fileExists(atPath: f.artifacts[0].destinationURL.path))
    }

    @Test @MainActor func invalidSettingsBlockLaunchUntilExplicitReset() throws {
        let f = try fixture(); defer { f.clean() }
        let name = "27b-invalid-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("obsolete-mode", forKey: "serverBindMode")
        defaults.set("obsolete-strength", forKey: "orcabonsaiAblationStrength")
        defaults.set("obsolete-language", forKey: "appLanguage")
        defaults.set(["unknown-component"], forKey: "damagedComponents")
        let controller = ServiceController(config: f.config, requiresInstanceLock: false,
            preferences: AppPreferences(defaults: defaults), processManager: StubServerProcessManager(), defaults: defaults,
            healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        controller.refreshInstallationStatus()
        #expect(controller.installationStatus == .failed)
        #expect(controller.settingsValidationError != nil)
        #expect(!controller.canStart)
        #expect(!controller.canRestart)
        #expect(defaults.string(forKey: "serverBindMode") == "obsolete-mode")
        controller.resetInvalidSettings()
        #expect(controller.settingsValidationError == nil)
        #expect(controller.ablationStrength == .aggressive)
        #expect(defaults.string(forKey: "orcabonsaiAblationStrength") == "2.0")
        #expect(defaults.string(forKey: "serverBindMode") == ServerBindMode.loopback.rawValue)
        #expect(controller.hasDamagedComponents)
        #expect(Set(defaults.stringArray(forKey: "damagedComponents")!) == Set(InstallationComponent.allCases.map(\.rawValue)))
    }

}

private final class CredentialTrapProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let leaked = request.value(forHTTPHeaderField: "Authorization") != nil
        let payload = "llamacpp:prompt_tokens_total 1\nllamacpp:tokens_predicted_total \(leaked ? 777 : 1)\nllamacpp:prompt_tokens_cached_total 0\nllamacpp:prompt_tokens_seconds 0\nllamacpp:predicted_tokens_seconds 0\nllamacpp:requests_processing 0\nllamacpp:requests_deferred 0\nllamacpp:n_tokens_max 0\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
