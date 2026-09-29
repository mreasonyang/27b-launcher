import Foundation
import Testing
@testable import Launcher27B

/// Covers migration safety behavior: destination volume validation,
/// stale staging cleanup, non-destructive failure handling and destination adoption.
@Suite(.serialized)
struct StorageMigrationSafetyTests {
    private struct Fixture {
        let root: URL
        let modelURL: URL
        let projectorURL: URL
        let config: LauncherConfig
        let artifacts: [InstallationArtifact]
        let destinationParent: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func makeFixture(_ label: String, modelBytes: Int = 4096) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-storage-safety-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let modelDirectory = support.appending(path: "models/27B", directoryHint: .isDirectory)
        let modelURL = modelDirectory.appending(path: "model.gguf")
        let projectorURL = modelDirectory.appending(path: "projector.gguf")
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x27, count: modelBytes).write(to: modelURL)
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
                expectedByteCount: Int64(modelBytes),
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
        return Fixture(
            root: root,
            modelURL: modelURL,
            projectorURL: projectorURL,
            config: config,
            artifacts: artifacts,
            destinationParent: root.appending(path: "external", directoryHint: .isDirectory)
        )
    }

    private static let destinationFolderName = "Bonsai2 Models"
    private static let stagingPrefix = ".Bonsai2 Models.copy-"

    // MARK: - Mounted volume fixture

    /// A real, non-boot volume backed by a sparse disk image. The allocation behavior this
    /// suite guards (`volumeAvailableCapacityForImportantUsage` is 0 off the boot
    /// volume) can only be reproduced against a real volume, not an injected
    /// descriptor.
    private struct MountedVolume {
        let mountPoint: URL
        let workDirectory: URL
    }

    /// Runs a tool to completion. A watchdog kills it if it does not finish, so a
    /// `hdiutil` blocked on disk arbitration can never hang the whole suite.
    private static func runTool(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 120
    ) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw NSError(
                domain: "StorageMigrationSafetyTests",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(arguments.joined(separator: " ")) timed out",
                ]
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "StorageMigrationSafetyTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(arguments.joined(separator: " ")) failed",
                ]
            )
        }
    }

    private static func mountSparseVolume(
        label: String,
        size: String,
        fileSystem: String = "APFS"
    ) throws -> MountedVolume {
        let work = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-mount-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let image = work.appending(path: "volume.sparseimage")
        let mountPoint = work.appending(path: "mnt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            // The volume name is unique too: two concurrent test runs mounting the
            // same label fight over disk arbitration.
            let volumeName = "L27B-\(label)-\(UUID().uuidString.prefix(8))"
            try runTool("/usr/bin/hdiutil", [
                "create", "-size", size, "-fs", fileSystem, "-volname", volumeName,
                "-type", "SPARSE", "-quiet", image.path,
            ])
            try runTool("/usr/bin/hdiutil", [
                "attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path, "-quiet",
            ])
        } catch {
            try? runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        return MountedVolume(mountPoint: mountPoint, workDirectory: work)
    }

    private static func unmount(_ volume: MountedVolume) {
        do {
            try runTool("/usr/bin/hdiutil", ["detach", volume.mountPoint.path, "-quiet"])
        } catch {
            try? runTool("/usr/bin/hdiutil", ["detach", volume.mountPoint.path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: volume.workDirectory)
    }

    /// Whether this machine can actually create and attach a disk image.
    ///
    /// On a sandboxed or VM CI runner `hdiutil` is either absent or cannot reach disk
    /// arbitration, and every probe below would fail the build instead of skipping.
    /// The probe is a full create/attach/detach cycle — the only honest signal — and it
    /// detaches whatever it attached before returning.
    private static let diskImageMountingAvailable: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else {
            return false
        }
        let work = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-mount-probe-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let image = work.appending(path: "probe.sparseimage")
        let mountPoint = work.appending(path: "mnt", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(
                at: mountPoint,
                withIntermediateDirectories: true
            )
            try runTool("/usr/bin/hdiutil", [
                "create", "-size", "16m", "-fs", "APFS", "-volname", "L27BProbe",
                "-type", "SPARSE", "-quiet", image.path,
            ], timeout: 60)
            try runTool("/usr/bin/hdiutil", [
                "attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path, "-quiet",
            ], timeout: 60)
            try runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"], timeout: 60)
            return true
        } catch {
            try? runTool(
                "/usr/bin/hdiutil",
                ["detach", mountPoint.path, "-force", "-quiet"],
                timeout: 60
            )
            return false
        }
    }()

    /// Lets a migration be suspended deterministically mid-copy so a second manager
    /// can be exercised while the first one still holds its staging directory.
    private actor MigrationPause {
        private var didPause = false
        private var isReleased = false
        private var pausedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            if didPause { return }
            didPause = true
            pausedWaiter?.resume()
            pausedWaiter = nil
            if isReleased { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilPaused() async {
            if didPause { return }
            await withCheckedContinuation { pausedWaiter = $0 }
        }

        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    // MARK: - Destination volume validation

    @Test
    func refusesReadOnlyDestination() async throws {
        let fixture = try Self.makeFixture("read-only")
        defer { fixture.cleanup() }
        let descriptor = ModelStorageDestinationDescriptor(
            fileSystemName: "apfs",
            isLocal: true,
            isReadOnly: true,
            supportsFilesAbove4GB: true,
            availableBytes: nil
        )
        let manager = ModelStorageManager(
            config: fixture.config,
            artifacts: fixture.artifacts,
            volumeDescriptorProvider: { _ in descriptor }
        )

        await #expect(throws: ModelStorageError.destinationReadOnly) {
            try await manager.migrate(to: fixture.destinationParent)
        }
        // Refused before any data was written.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
        #expect(try FileChecksum().sha256(at: fixture.config.modelFile) == fixture.artifacts[0].expectedSHA256)
    }

    @Test
    func refusesNetworkDestination() async throws {
        let fixture = try Self.makeFixture("network")
        defer { fixture.cleanup() }
        let descriptor = ModelStorageDestinationDescriptor(
            fileSystemName: "smbfs",
            isLocal: false,
            isReadOnly: false,
            supportsFilesAbove4GB: true,
            availableBytes: nil
        )
        let manager = ModelStorageManager(
            config: fixture.config,
            artifacts: fixture.artifacts,
            volumeDescriptorProvider: { _ in descriptor }
        )

        await #expect(throws: ModelStorageError.destinationIsNetworkVolume) {
            try await manager.migrate(to: fixture.destinationParent)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
    }

    @Test
    func refusesFileSystemThatCannotHoldLargeModelFiles() async throws {
        let fixture = try Self.makeFixture("fat32")
        defer { fixture.cleanup() }

        // A sparse file with a logical size above the FAT32 per-file ceiling, so the
        // refusal is triggered without writing 4 GB of real data.
        let oversized = fixture.root.appending(path: "support/models/27B/oversized.gguf")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(
            atOffset: UInt64(ModelStorageDestinationProbe.fourGigabyteLimit) + 1
        )
        try handle.close()
        let logicalSize = try oversized.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(logicalSize) > ModelStorageDestinationProbe.fourGigabyteLimit else {
            // The filesystem cannot express a >4 GB logical size; nothing to assert.
            return
        }

        let descriptor = ModelStorageDestinationDescriptor(
            fileSystemName: "msdos",
            isLocal: true,
            isReadOnly: false,
            supportsFilesAbove4GB: false,
            availableBytes: nil
        )
        let manager = ModelStorageManager(
            config: fixture.config,
            artifacts: fixture.artifacts,
            volumeDescriptorProvider: { _ in descriptor }
        )

        do {
            _ = try await manager.migrate(to: fixture.destinationParent)
            Issue.record("Migration unexpectedly accepted a FAT32 destination")
        } catch let error as ModelStorageError {
            guard case let .destinationFileSystemUnsupported(fileSystem, largest) = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
            #expect(fileSystem == "msdos")
            #expect(largest > ModelStorageDestinationProbe.fourGigabyteLimit)
        }

        // Fails fast: nothing was copied to the destination volume.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
        let leftover = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationParent.path
        )
        #expect(leftover.isEmpty)
    }

    @Test
    func realVolumeProbeReportsLocalWritableTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
        guard let descriptor = ModelStorageDestinationProbe.descriptor(at: root) else {
            // Volume capability probing is unavailable in this environment.
            return
        }
        #expect(descriptor.isReadOnly == false)
        #expect(descriptor.isLocal)
        #expect(!descriptor.fileSystemName.isEmpty)
        #expect(descriptor.supportsFilesAbove4GB)
        #expect(ModelStorageDestinationProbe.fileSystemName(at: root) != nil)
    }

    /// `_PC_FILESIZEBITS` reports 33 for FAT32 (measured), so a `> 32` test calls a
    /// 4 GB-capped volume capable. The filesystem name must be the primary signal,
    /// and an unknown filesystem must not default to capable.
    @Test
    func sizeRestrictedFileSystemsAreNeverReportedCapable() throws {
        let directory = FileManager.default.temporaryDirectory
        for name in ["msdos", "FAT", "vfat"] {
            #expect(
                !ModelStorageDestinationProbe.supportsFileSizesAbove4GB(
                    at: directory,
                    fileSystemName: name
                ),
                "\(name) caps files at 4 GB"
            )
        }
        // `pathconf` on this APFS volume reports more than 32 bits, which is exactly
        // why it cannot be treated as proof of capability.
        #expect(
            !ModelStorageDestinationProbe.supportsFileSizesAbove4GB(
                at: directory,
                fileSystemName: "unknown"
            ),
            "an unknown filesystem must not fall open to capable"
        )
        #expect(
            !ModelStorageDestinationProbe.supportsFileSizesAbove4GB(
                at: directory,
                fileSystemName: "some-new-fs"
            )
        )
        #expect(
            ModelStorageDestinationProbe.supportsFileSizesAbove4GB(
                at: directory,
                fileSystemName: "apfs"
            )
        )
    }

    /// The same refusal against a genuinely mounted FAT32 volume, with the real
    /// probe (macOS reports FAT32 as `msdos`).
    @Test(.enabled(if: StorageMigrationSafetyTests.diskImageMountingAvailable))
    func refusesRealFat32VolumeForModelFilesAboveFourGigabytes() async throws {
        let fixture = try Self.makeFixture("real-fat32")
        defer { fixture.cleanup() }

        // Sparse file with a >4 GB logical size, so no 4 GB is actually written.
        let oversized = fixture.config.modelsDirectory.appending(path: "27B/oversized.gguf")
        guard FileManager.default.createFile(atPath: oversized.path, contents: nil) else {
            Issue.record("Could not create the oversized source file")
            return
        }
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ModelStorageDestinationProbe.fourGigabyteLimit) + 1)
        try handle.close()

        let volume = try Self.mountSparseVolume(label: "fat32", size: "64m", fileSystem: "MS-DOS")
        defer { Self.unmount(volume) }
        let destinationParent = volume.mountPoint.appending(
            path: "models",
            directoryHint: .isDirectory
        )

        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        do {
            _ = try await manager.migrate(to: destinationParent)
            Issue.record("Migration unexpectedly accepted a FAT32 destination")
        } catch let error as ModelStorageError {
            guard case let .destinationFileSystemUnsupported(fileSystem, largest) = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
            #expect(fileSystem == "msdos")
            #expect(largest > ModelStorageDestinationProbe.fourGigabyteLimit)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
    }

    // MARK: - Real (non-boot) destination volumes

    /// `volumeAvailableCapacityForImportantUsage` can be 0 on some volumes, so
    /// migrating to a real, roomy external volume was refused as "insufficient
    /// disk space: available Zero kB". A real mounted image is exercised
    /// deliberately — an injected descriptor would hide this.
    @Test(.enabled(if: StorageMigrationSafetyTests.diskImageMountingAvailable))
    func migratesToRealNonBootVolumeWithAmpleSpace() async throws {
        let fixture = try Self.makeFixture("real-volume")
        defer { fixture.cleanup() }
        let volume = try Self.mountSparseVolume(label: "roomy", size: "2g")
        defer { Self.unmount(volume) }

        let destinationParent = volume.mountPoint.appending(
            path: "models",
            directoryHint: .isDirectory
        )
        // No injected descriptor: the real probe is what was broken.
        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        let result = try await manager.migrate(to: destinationParent)

        #expect(result.isAvailable)
        #expect(result.isRelocated)
        let expected = destinationParent
            .appending(path: Self.destinationFolderName)
            .resolvingSymlinksInPath()
            .path
        #expect(result.url.resolvingSymlinksInPath().path == expected)
        #expect(
            try FileChecksum().sha256(at: fixture.config.modelFile)
                == fixture.artifacts[0].expectedSHA256
        )
        #expect(
            try FileChecksum().sha256(at: fixture.config.projectorFile)
                == fixture.artifacts[1].expectedSHA256
        )
    }

    /// The fix must not turn the space check off: a real volume that genuinely
    /// cannot hold the models is still refused, with an honest capacity figure.
    @Test(.enabled(if: StorageMigrationSafetyTests.diskImageMountingAvailable))
    func refusesRealVolumeWithoutEnoughSpace() async throws {
        let fixture = try Self.makeFixture("full-volume")
        defer { fixture.cleanup() }
        let volume = try Self.mountSparseVolume(label: "small", size: "256m")
        defer { Self.unmount(volume) }

        let destinationParent = volume.mountPoint.appending(
            path: "models",
            directoryHint: .isDirectory
        )
        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)

        do {
            _ = try await manager.migrate(to: destinationParent)
            Issue.record("Migration unexpectedly accepted a destination with no room")
        } catch let error as ModelStorageError {
            guard case let .insufficientDiskSpace(required, available) = error else {
                Issue.record("Unexpected migration error: \(error)")
                return
            }
            // Before the fix this was 0, which is both wrong and useless to the user.
            #expect(available > 0)
            #expect(available < required)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
    }

    // MARK: - Stale staging cleanup

    @Test
    func preservesUnjournaledDirectoriesDuringMigration() async throws {
        let fixture = try Self.makeFixture("stale-sweep")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.destinationParent,
            withIntermediateDirectories: true
        )
        let stale = fixture.destinationParent.appending(
            // An *owned* staging name (`<prefix><pid>-<token>.<uuid>`). A bare
            // `<prefix><uuid>` name is no longer swept by discovery — it is not proof
            // of ownership — so it would not exercise this path. The pid is outside the
            // usable range, so the owner is reliably not alive.
            path: "\(Self.stagingPrefix)999999-a1b2c3d4.\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: stale.appending(path: "27B", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x2B, count: 65536).write(to: stale.appending(path: "27B/model.gguf"))
        #expect(FileManager.default.fileExists(atPath: stale.path))

        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        let result = try await manager.migrate(to: fixture.destinationParent)

        #expect(result.isAvailable)
        #expect(FileManager.default.fileExists(atPath: stale.path))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
    }





    /// A prefix test is not a namespace test. A directory whose name merely *starts*
    /// like a staging directory must not be deleted because the journal names it.


    /// The journal is a single shared file while `activeStagingPath` is per instance,
    /// so without an owner token a second launcher deletes the first launcher's
    /// in-flight staging directory and fails its migration with a misleading
    /// checksum error.
    @Test
    func secondInstanceNeverReclaimsAnotherInstancesLiveStaging() async throws {
        let fixture = try Self.makeFixture("instance-scope", modelBytes: 4 * 1024 * 1024)
        defer { fixture.cleanup() }
        let migrating = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        let polling = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        let pause = MigrationPause()

        let migration = Task {
            try await migrating.migrate(to: fixture.destinationParent) { progress in
                if progress.phase == .copying, progress.stageCompletedBytes > 0 {
                    await pause.pause()
                }
            }
        }
        await pause.waitUntilPaused()

        let stagingNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationParent.path
        ).filter { $0.hasPrefix(Self.stagingPrefix) }
        #expect(stagingNames.count == 1)
        let journal = fixture.config.supportDirectory.appending(path: "model-copy.json")
        #expect(FileManager.default.fileExists(atPath: journal.path))

        // A second launcher polls the very same support directory while the first is
        // still copying. It must not touch the in-flight work.
        _ = try await polling.locationStatus()

        #expect(FileManager.default.fileExists(atPath: journal.path))
        for name in stagingNames {
            #expect(
                FileManager.default.fileExists(
                    atPath: fixture.destinationParent.appending(path: name).path
                )
            )
        }

        await pause.release()
        let result = try await migration.value
        #expect(result.isAvailable)
        #expect(
            try FileChecksum().sha256(at: fixture.config.modelFile)
                == fixture.artifacts[0].expectedSHA256
        )
    }

    // MARK: - Non-destructive failure path



    /// File names and byte counts are not proof. An entry at the canonical path with
    /// exactly the expected sizes but different bytes must not cost the parked
    /// original — a size-only check would delete it here.


    /// A peer removes the parked original and leaves the canonical path pointing at
    /// the verified copy while `migrate` handles a failure. The destination must not
    /// be deleted just because an entry exists at the canonical path.


    /// `truncate(atOffset:)` leaves a sparse file on APFS (measured: 7.2 GB logical,
    /// 4 KB allocated), so it does not detect a destination that cannot hold the
    /// data. `reserveSpace` must actually reserve the blocks.


    /// A destination whose volume cannot be inspected must fail validation rather
    /// than proceeding as if it had been checked.
    @Test
    func unavailableVolumeDescriptorDoesNotBypassValidation() async throws {
        let fixture = try Self.makeFixture("nil-descriptor")
        defer { fixture.cleanup() }
        let manager = ModelStorageManager(
            config: fixture.config,
            artifacts: fixture.artifacts,
            volumeDescriptorProvider: { _ in nil }
        )

        await #expect(throws: ModelStorageError.self) {
            try await manager.migrate(to: fixture.destinationParent)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationParent.appending(path: Self.destinationFolderName).path
            )
        )
        #expect(
            try FileChecksum().sha256(at: fixture.config.modelFile) == fixture.artifacts[0].expectedSHA256
        )
    }

    // MARK: - Destination adoption



    @Test
    func rejectsExistingDestinationThatIsNotACopyOfTheModels() async throws {
        let fixture = try Self.makeFixture("foreign-destination")
        defer { fixture.cleanup() }
        let destination = fixture.destinationParent.appending(
            path: Self.destinationFolderName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "unrelated", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x11, count: 128).write(to: destination.appending(path: "unrelated/data"))

        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        await #expect(throws: ModelStorageError.destinationExists) {
            try await manager.migrate(to: fixture.destinationParent)
        }
        #expect(
            FileManager.default.fileExists(atPath: destination.appending(path: "unrelated/data").path)
        )
        #expect(try FileChecksum().sha256(at: fixture.config.modelFile) == fixture.artifacts[0].expectedSHA256)
    }

    @Test
    func reportsIncompleteExistingDestinationCopy() async throws {
        let fixture = try Self.makeFixture("corrupt-destination")
        defer { fixture.cleanup() }
        // Same byte count as the models, different content: the filesystem-level
        // structure matches, so the checksum verification is what rejects it.
        let destination = fixture.destinationParent.appending(
            path: Self.destinationFolderName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "27B", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x55, count: 4096).write(to: destination.appending(path: "27B/model.gguf"))
        try Data(repeating: 0x66, count: 2048).write(
            to: destination.appending(path: "27B/projector.gguf")
        )

        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        await #expect(throws: ModelStorageError.destinationContainsIncompleteCopy) {
            try await manager.migrate(to: fixture.destinationParent)
        }
        // The original models are untouched and the rejected copy is left alone.
        #expect(try FileChecksum().sha256(at: fixture.config.modelFile) == fixture.artifacts[0].expectedSHA256)
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appending(path: "27B/model.gguf").path
            )
        )
    }

    // MARK: - Retained model copy

    @Test
    func reportsRetainedSourceCopyWhenOldLocationCannotBeRemoved() async throws {
        let fixture = try Self.makeFixture("retained-legacy")
        let secondParent = fixture.root.appending(path: "external-2", directoryHint: .isDirectory)
        defer { fixture.cleanup() }

        let manager = ModelStorageManager(config: fixture.config, artifacts: fixture.artifacts)
        _ = try await manager.migrate(to: fixture.destinationParent)

        let legacy = fixture.destinationParent.appending(path: Self.destinationFolderName)
        // Mark a *nested* directory immutable: its contents then cannot be unlinked, so
        // removing the old location fails while nothing is destroyed. (Marking the top
        // directory instead would let `removeItem` empty it before failing.)
        let protectedDirectory = legacy.appending(path: "27B", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: protectedDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: protectedDirectory.path
            )
        }

        // Skip when this environment does not enforce the immutable flag.
        if (try? FileManager.default.removeItem(at: legacy)) != nil {
            return
        }
        // The probe must not have damaged the models we are about to re-migrate.
        #expect(
            FileManager.default.fileExists(atPath: legacy.appending(path: "27B/model.gguf").path)
        )

        let result = try await manager.migrate(to: secondParent)

        guard case let .sourceLocationRetained(byteCount) = result.notice else {
            Issue.record(
                "Expected a retained-legacy-location notice, got \(String(describing: result.notice))"
            )
            return
        }
        #expect(byteCount > 0)
        #expect(result.url.path == secondParent.appending(path: Self.destinationFolderName).path)
        #expect(try FileChecksum().sha256(at: fixture.config.modelFile) == fixture.artifacts[0].expectedSHA256)
    }
}
