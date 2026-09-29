import CryptoKit
import Foundation
import Testing
@testable import Launcher27B

/// Coverage for download and installation behavior: crash-safe resume,
/// transient HTTP retries, checksum-mismatch preservation, hardware preflight and the
/// copy-based install path. Everything network-facing runs against a local Python
/// fixture server; no test touches the public internet.
@Suite(.serialized)
struct InstallerRobustnessTests {
    private static let payloadByteCount: Int64 = 8 * 1024 * 1024
    /// Must match `robustness_probe_server.ETAG`.
    private static let fixtureETag = "\"launcher27b-robustness-fixture-v1\""

    // MARK: - Resume after a forced quit

    @Test
    func resumesFromCapturedInFlightCheckpointAfterSimulatedCrash() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        // A slow fixture so the once-a-second progress tick (the only thing that runs
        // during a force-quit) is guaranteed to have fired before the interruption.
        let server = try startServer(mode: "serve", logURL: logURL, chunkDelay: 0.08)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        let gate = FileGate(url: progressURL)
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let firstAttempt = Task {
            try await downloader.download(
                artifact: artifact,
                to: partialURL,
                resumeDataURL: resumeMarkerURL,
                progressDataURL: progressURL
            ) { update in
                await gate.record(update)
            }
        }

        await gate.wait()
        #expect(
            FileManager.default.fileExists(atPath: progressURL.path),
            "the in-flight reporter must have written the crash checkpoint before the interruption"
        )

        // Read the crash state *before* interrupting. This is the tick's output, not
        // anything the test or a completion callback writes below.
        let tickState = try DownloadProgressCheckpoint().readResumeMarker(from: progressURL)
        #expect(
            tickState.validator == Self.fixtureETag,
            "the in-flight progress tick must persist the validator a crash needs"
        )
        #expect(tickState.bytes > 0)

        // Let the partial outgrow the captured checkpoint; resume must use the
        // captured durable offset, not the larger file size.
        try await Task.sleep(for: .milliseconds(400))
        let partialSize = try fileSize(at: partialURL)
        #expect(partialSize > tickState.bytes)

        firstAttempt.cancel()
        do {
            _ = try await firstAttempt.value
            Issue.record("Expected the interrupted download to surface cancellation")
        } catch {
            #expect(ServiceController.isInstallationCancellation(error))
        }

        // Simulate a force-quit: URLSession resume data was never produced at all and
        // no URLSession completion callback ran. Deleting the resume marker removes
        // anything a callback might have written.
        try? FileManager.default.removeItem(at: resumeMarkerURL)

        // Restore exactly the checkpoint captured during the transfer; a crash has
        // no completion callback to update it.
        try DownloadProgressCheckpoint().writeResumeMarker(tickState, to: progressURL)

        // A brand-new downloader stands in for a relaunched process: all resume state
        // must come from disk, not from in-memory URLSession state.
        let observation = DownloadObservation()
        let freshDownloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await freshDownloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: resumeMarkerURL,
            progressDataURL: progressURL
        ) { update in
            await observation.record(update)
        }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        #expect(await observation.sawResuming)
        #expect(!FileManager.default.fileExists(atPath: progressURL.path))
        #expect(!FileManager.default.fileExists(atPath: resumeMarkerURL.path))

        let log = try String(contentsOf: logURL, encoding: .utf8)
        let rangeStarts = self.rangeStarts(in: log)
        // The offset came from the tick's checkpoint, not from the (larger) file size
        // the crash could have left behind.
        #expect(rangeStarts.contains(tickState.bytes))
        #expect(
            !rangeStarts.contains(partialSize),
            "the resume used the on-disk size instead of the crash checkpoint"
        )
        // The resume really was conditional: the crash-time validator came from the
        // progress checkpoint and was sent back as If-Range.
        #expect(log.contains("If-Range:\(Self.fixtureETag)"))
    }

    @Test
    func restartsCleanlyWhenServerIgnoresRange() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "ignore_range", logURL: nil)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        // Seed a bogus 2 MB partial that a Range-unaware server would otherwise corrupt.
        let seededBytes: Int64 = 2 * 1_048_576
        try Data(repeating: 0xAB, count: Int(seededBytes)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: seededBytes, validator: Self.fixtureETag), to: progressURL)

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: resumeMarkerURL,
            progressDataURL: progressURL
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)

        let handle = try FileHandle(forReadingFrom: downloadedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        #expect(prefix == Data((0..<256).map { UInt8($0) }))
    }

    @Test
    func restartsFromZeroWhenServerRejectsRange() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "reject_range_416", logURL: nil)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let progressURL = root.appending(path: "model.progress")
        let seededBytes: Int64 = 1_048_576
        try Data(repeating: 0xCD, count: Int(seededBytes)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: seededBytes, validator: Self.fixtureETag), to: progressURL)

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: makeArtifact(
                destinationURL: root.appending(path: "model.gguf"),
                port: server.port
            ),
            to: partialURL,
            resumeDataURL: root.appending(path: "model.resume"),
            progressDataURL: progressURL
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
    }

    // MARK: - Transient HTTP statuses

    @Test
    func retriesServiceUnavailableWithRetryAfter() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "flaky_503", logURL: nil)
        defer { server.process.terminate() }

        let observation = DownloadObservation()
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let destinationURL = root.appending(path: "model.download")
        let downloadedURL = try await downloader.download(
            artifact: makeArtifact(
                destinationURL: root.appending(path: "model.gguf"),
                port: server.port
            ),
            to: destinationURL,
            resumeDataURL: root.appending(path: "model.resume"),
            progressDataURL: root.appending(path: "model.progress")
        ) { update in
            await observation.record(update)
        }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        #expect(await observation.sawWaitingForNetwork)
    }

    @Test
    func retriesTooManyRequestsWithRetryAfter() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "flaky_429", logURL: nil)
        defer { server.process.terminate() }

        let observation = DownloadObservation()
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: makeArtifact(
                destinationURL: root.appending(path: "model.gguf"),
                port: server.port
            ),
            to: root.appending(path: "model.download"),
            resumeDataURL: root.appending(path: "model.resume"),
            progressDataURL: root.appending(path: "model.progress")
        ) { update in
            await observation.record(update)
        }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        #expect(await observation.sawWaitingForNetwork)
    }

    @Test
    func classifiesRetryableFailures() {
        #expect(ArtifactDownloader.isRetryable(RetryableHTTPError(statusCode: 503, retryAfterSeconds: nil)))
        #expect(ArtifactDownloader.isRetryable(RetryableHTTPError(statusCode: 500, retryAfterSeconds: nil)))
        #expect(ArtifactDownloader.isRetryable(RetryableHTTPError(statusCode: 429, retryAfterSeconds: 3)))
        #expect(!ArtifactDownloader.isRetryable(RetryableHTTPError(statusCode: 404, retryAfterSeconds: nil)))
        #expect(!ArtifactDownloader.isRetryable(RetryableHTTPError(statusCode: 403, retryAfterSeconds: nil)))

        // Captive portals on hotel/airport Wi-Fi fail the TLS handshake.
        #expect(ArtifactDownloader.isRetryable(URLError(.secureConnectionFailed)))
        #expect(ArtifactDownloader.isRetryable(URLError(.serverCertificateUntrusted)))
        #expect(ArtifactDownloader.isRetryable(URLError(.networkConnectionLost)))
        #expect(ArtifactDownloader.isRetryable(URLError(.timedOut)))
        #expect(ArtifactDownloader.isRetryable(ArtifactDownloadError.incompleteDownload))

        // Non-transient problems must surface immediately instead of looping.
        #expect(!ArtifactDownloader.isRetryable(URLError(.badURL)))
        #expect(!ArtifactDownloader.isRetryable(ArtifactDownloadError.diskFull))
        #expect(!ArtifactDownloader.isRetryable(ArtifactDownloadError.unexpectedContentType))
        #expect(!ArtifactDownloader.isRetryable(CocoaError(.fileWriteOutOfSpace)))

        #expect(
            ArtifactDownloader.retryDelaySeconds(
                for: RetryableHTTPError(statusCode: 503, retryAfterSeconds: 7),
                attempt: 0,
                scheduledDelays: [1, 2, 4]
            ) == 7
        )
        #expect(
            ArtifactDownloader.retryDelaySeconds(
                for: RawServerError(),
                attempt: 3,
                scheduledDelays: [1, 2, 4]
            ) == 4
        )
    }

    // MARK: - Disk-full and raw NSError mapping

    @Test
    func mapsDiskFullFailuresToActionableErrors() {
        #expect(
            ArtifactDownloader.userFacingError(for: CocoaError(.fileWriteOutOfSpace))
                as? ArtifactDownloadError == .diskFull
        )
        #expect(
            ArtifactDownloader.userFacingError(for: POSIXError(.ENOSPC))
                as? ArtifactDownloadError == .diskFull
        )
        #expect(
            ArtifactDownloader.userFacingError(for: URLError(.cannotWriteToFile))
                as? ArtifactDownloadError == .diskFull
        )
        #expect(
            ArtifactDownloader.userFacingError(for: URLError(.notConnectedToInternet))
                as? ArtifactDownloadError == .networkInterrupted
        )
        #expect(
            ArtifactDownloader.userFacingError(for: CocoaError(.fileWriteNoPermission))
                as? ArtifactDownloadError == .fileWriteFailed
        )

        #expect(InstallerError.wrapping(CocoaError(.fileWriteOutOfSpace)) as? InstallerError == .diskFull)
        #expect(InstallerError.wrapping(POSIXError(.ENOSPC)) as? InstallerError == .diskFull)
        #expect(
            InstallerError.wrapping(CocoaError(.fileWriteNoPermission)) as? InstallerError
                == .permissionDenied
        )
        #expect(InstallerError.wrapping(CancellationError()) is CancellationError)
    }

    // MARK: - Content sanity and checksum-mismatch preservation

    @Test
    func rejectsHTMLBodyReturnedWithOKStatus() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "html200", logURL: nil)
        defer { server.process.terminate() }

        let destinationURL = root.appending(path: "model.download")
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])

        do {
            _ = try await downloader.download(
                artifact: makeArtifact(
                destinationURL: root.appending(path: "model.gguf"),
                port: server.port
            ),
                to: destinationURL,
                resumeDataURL: root.appending(path: "model.resume"),
                progressDataURL: root.appending(path: "model.progress")
            ) { _ in }
            Issue.record("Expected an HTML error body to be rejected")
        } catch {
            #expect((error as? ArtifactDownloadError) == .unexpectedContentType)
        }

        // Nothing close to the 8 MB payload may ever reach disk.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            #expect(try fileSize(at: destinationURL) < 1_048_576)
        }
    }

    @Test
    func checksumMismatchPreservesPartialAndAllowsReverify() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let goodContents = Data(repeating: 0x11, count: 4096)
        let badContents = Data(repeating: 0x22, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(goodContents.count),
            expectedSHA256: sha256Hex(of: goodContents),
            kind: .file
        )

        let downloadsDirectory = config.downloadsDirectory
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = downloadsDirectory.appending(path: "model.download")
        try badContents.write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 4096, validator: nil), to: config.progressDataURL(for: .model))
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 4096, validator: nil), to: config.resumeDataURL(for: .model))

        let installer = BonsaiInstaller(config: config)
        do {
            try await installer.install(artifacts: [artifact]) { _ in }
            Issue.record("Expected a checksum mismatch")
        } catch {
            guard case .checksumMismatch = (error as? InstallerError) else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        // Hours of user bandwidth must survive the failure.
        #expect(FileManager.default.fileExists(atPath: partialURL.path))
        #expect(FileManager.default.fileExists(atPath: config.progressDataURL(for: .model).path))
        #expect(FileManager.default.fileExists(atPath: config.resumeDataURL(for: .model).path))
        #expect(!FileManager.default.fileExists(atPath: config.modelFile.path))

        // A re-verify path exists and still reports the same verdict ...
        await #expect(throws: InstallerError.checksumMismatch(component: .model)) {
            _ = try await installer.reverifyPreservedDownload(for: artifact)
        }
        #expect(FileManager.default.fileExists(atPath: partialURL.path))

        // ... and installing succeeds once the bytes are actually correct.
        try goodContents.write(to: partialURL)
        let recovered = try await installer.reverifyPreservedDownload(for: artifact)
        #expect(recovered)
        #expect(try Data(contentsOf: config.modelFile) == goodContents)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    // MARK: - Transfer branch, disk accounting, and staging cleanup

    @Test
    func installRenamesInPlaceOnTheSameVolumeWithoutExtraSpace() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x33, count: 8192)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )

        let partialURL = config.downloadsDirectory.appending(path: "model.download")
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(to: partialURL)

        let installer = BonsaiInstaller(config: config)
        // The scratch paths really are on one volume, so this exercises the rename branch.
        #expect(try await installer.isSameVolume(partialURL, config.modelFile))
        #expect(
            BonsaiInstaller.systemVolumeIdentity(for: partialURL)
                == BonsaiInstaller.systemVolumeIdentity(for: config.modelFile)
        )

        // A rename needs no destination space: the 2x peak the copy path would demand
        // must not appear once the download is already complete.
        #expect(try await installer.diskSpaceRequirements(for: [artifact]).isEmpty)

        let phases = PhaseRecorder()
        try await installer.install(artifacts: [artifact]) { progress in
            await phases.record(progress.phase)
        }

        #expect(try Data(contentsOf: config.modelFile) == contents)
        #expect(await phases.phases.contains(.verifying))
        #expect(await phases.phases.contains(.installing))
        #expect(!(await phases.phases.contains(.copying)))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        let stagingURL = config.modelFile.deletingLastPathComponent()
            .appending(path: ".\(config.modelFile.lastPathComponent).installing")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func installCopiesAcrossVolumesAndNeverMovesTheSource() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x34, count: 8192)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )

        let partialURL = config.downloadsDirectory.appending(path: "model.download")
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(to: partialURL)

        // Pretend the destination lives on another volume; a second real volume is not
        // available to a unit test.
        let installer = BonsaiInstaller(config: config, volumeIdentity: { url in
            url.path.contains("models") ? 2 : 1
        })
        #expect(!(try await installer.isSameVolume(partialURL, config.modelFile)))

        let requirements = try await installer.diskSpaceRequirements(for: [artifact])
        #expect(requirements.values.reduce(0, +) == artifact.expectedByteCount)

        let phases = PhaseRecorder()
        try await installer.install(artifacts: [artifact]) { progress in
            await phases.record(progress.phase)
        }

        #expect(try Data(contentsOf: config.modelFile) == contents)
        #expect(await phases.phases.contains(.copying))
        // Copy-then-verify-then-delete: the source is gone only after a successful swap.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        let stagingURL = config.modelFile.deletingLastPathComponent()
            .appending(path: ".\(config.modelFile.lastPathComponent).installing")
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func obsoleteInstallingNameIsNotAdoptedOrDeleted() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x35, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )

        // This name has no producer in the current file install transaction.
        let destinationDirectory = config.modelFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let stagingURL = destinationDirectory.appending(
            path: ".\(config.modelFile.lastPathComponent).installing"
        )
        try contents.write(to: stagingURL)

        let installer = BonsaiInstaller(config: config)
        try await installer.sweepStaleStagingEntries(for: [artifact])

        let partialURL = config.downloadsDirectory.appending(path: "model.download")
        #expect(try Data(contentsOf: stagingURL) == contents)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(try await installer.stagingLeftoverBytes(for: [artifact]) == 0)
    }

    @Test
    func resolvesDestinationVolumeThroughSymlinks() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Mirrors the post-migration layout: the models directory is a symlink to
        // another location, and only the resolved target's free space matters.
        let target = root.appending(path: "external/models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let link = support.appending(path: "models")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let destinationURL = link.appending(path: "27B/Ternary-Bonsai-2-27B-PQ2_0.gguf")
        let resolved = try BonsaiInstaller.volumeRoot(for: destinationURL)

        #expect(resolved.path == target.resolvingSymlinksInPath().path)
        let values = try resolved.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        #expect(values.volumeAvailableCapacityForImportantUsage != nil)
    }

    // MARK: - Installation verification

    @Test
    func verifiesInstalledArtifactsByDigest() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x66, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )
        let inspector = InstallationInspector()

        #expect(try await inspector.verify(artifact, config: config) == .missing)

        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: config.modelFile)

        // The structural check already says "installed", which is exactly why a digest
        // verification path is needed.
        #expect(try inspector.isInstalled(artifact, config: config))
        #expect(try inspector.artifactsRequiringVerification(from: [artifact], config: config).count == 1)
        #expect(try inspector.requiresVerification(artifact, config: config))
        #expect(try await inspector.verify(artifact, config: config) == .verified)

        // Same size, different bytes: size-only installation can never notice this.
        try Data(repeating: 0x77, count: contents.count).write(to: config.modelFile)
        #expect(try inspector.isInstalled(artifact, config: config))
        #expect(try await inspector.verify(artifact, config: config) == .checksumMismatch)

        try Data(repeating: 0x66, count: 128).write(to: config.modelFile)
        #expect(
            try await inspector.verify(artifact, config: config)
                == .sizeMismatch(expected: Int64(contents.count), actual: 128)
        )
    }

    // MARK: - Hardware preflight

    @Test
    func refusesNonArm64Machines() {
        let requirements = HardwareRequirements(
            architecture: "x86_64",
            physicalMemoryBytes: 64 * 1_073_741_824
        )
        #expect(requirements.assessment == .unsatisfied(
            .unsupportedArchitecture(current: "x86_64")
        ))
        #expect(!requirements.canInstall)
        #expect(requirements.assessment.issue != nil)
    }

    @Test
    func refusesLowMemoryMachines() {
        let requirements = HardwareRequirements(
            architecture: "arm64",
            physicalMemoryBytes: 8 * 1_073_741_824
        )
        #expect(requirements.assessment == .unsatisfied(
            .insufficientMemory(
                requiredBytes: HardwareRequirements.minimumPhysicalMemoryBytes,
                availableBytes: 8 * 1_073_741_824
            )
        ))
        #expect(!requirements.canInstall)
    }

    @Test
    func warnsOnMarginalMemoryAndAcceptsComfortableMachines() {
        let marginal = HardwareRequirements(
            architecture: "arm64",
            physicalMemoryBytes: 16 * 1_073_741_824
        )
        if case let .warning(issue) = marginal.assessment {
            #expect(issue == .limitedMemory(
                recommendedBytes: HardwareRequirements.recommendedPhysicalMemoryBytes,
                availableBytes: 16 * 1_073_741_824
            ))
        } else {
            Issue.record("16 GB should be a warning, got \(marginal.assessment)")
        }
        #expect(marginal.canInstall)

        let comfortable = HardwareRequirements(
            architecture: "arm64",
            physicalMemoryBytes: 36 * 1_073_741_824
        )
        #expect(comfortable.assessment == .satisfied)
        #expect(comfortable.assessment.isSatisfied)
        #expect(comfortable.canInstall)
    }

    @Test
    func currentMachineSnapshotIsPopulated() {
        let current = HardwareRequirements.current()
        #expect(!current.architecture.isEmpty)
        #expect(current.physicalMemoryBytes > 0)
        #expect(HardwareRequirements.requiredArchitecture == "arm64")
        #expect(
            HardwareRequirements.minimumPhysicalMemoryBytes
                < HardwareRequirements.recommendedPhysicalMemoryBytes
        )
    }

    // MARK: - Bounded retries

    @Test
    func boundsRetriesAgainstAPermanentServiceUnavailableEndpoint() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "always_503", logURL: logURL)
        defer { server.process.terminate() }

        let downloader = ArtifactDownloader()
        do {
            // Keep the failure bounded so a stalled implementation cannot hang the suite.
            _ = try await withTestDeadline(seconds: 120) {
                try await downloader.download(
                    artifact: makeArtifact(
                        destinationURL: root.appending(path: "model.gguf"),
                        port: server.port
                    ),
                    to: root.appending(path: "model.download"),
                    resumeDataURL: root.appending(path: "model.resume"),
                    progressDataURL: root.appending(path: "model.progress")
                ) { _ in }
            }
            Issue.record("Expected a permanently-503 endpoint to give up, not loop forever")
        } catch {
            guard let exhausted = error as? DownloadRetryExhaustedError else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(exhausted.attempts > 0)
            #expect(exhausted.lastFailure == .httpStatus(503))
        }

        // `Retry-After: 0` must still be spaced out and, above all, bounded. The
        // literal bound is deliberate: asserting against the policy constant would
        // move with the code and prove nothing.
        let requests = try requestCount(in: logURL)
        #expect(requests > 1, "the downloader should have retried at least once")
        #expect(requests <= 8, "request count must be bounded, saw \(requests)")
    }

    @Test
    func boundsRetriesWhenEveryResponseIsTruncated() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "truncate_body_200", logURL: logURL)
        defer { server.process.terminate() }

        // The captive-portal shape: a 200 that never delivers the payload. Every
        // attempt fails retryably, so without a cap this looped forever.
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        do {
            _ = try await withTestDeadline(seconds: 120) {
                try await downloader.download(
                    artifact: makeArtifact(
                        destinationURL: root.appending(path: "model.gguf"),
                        port: server.port
                    ),
                    to: root.appending(path: "model.download"),
                    resumeDataURL: root.appending(path: "model.resume"),
                    progressDataURL: root.appending(path: "model.progress")
                ) { _ in }
            }
            Issue.record("Expected a permanently-truncated response to give up")
        } catch {
            #expect(error is DownloadRetryExhaustedError)
        }

        let requests = try requestCount(in: logURL)
        #expect(requests > 1)
        #expect(requests <= 8, "request count must be bounded, saw \(requests)")
    }

    @Test
    func boundsAnAttemptAgainstAStalledEndpoint() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A listener that completes the TCP handshake and then never answers. No
        // URLSession may never call back for this shape; the attempt deadline must
        // return control to the bounded retry policy.
        let server = try startServer(mode: "stall", logURL: nil)
        defer { server.process.terminate() }

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0], attemptStallTimeoutSeconds: 1)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withTestDeadline(seconds: 60) {
                try await downloader.download(
                    artifact: makeArtifact(
                        destinationURL: root.appending(path: "model.gguf"),
                        port: server.port
                    ),
                    to: root.appending(path: "model.download"),
                    resumeDataURL: root.appending(path: "model.resume"),
                    progressDataURL: root.appending(path: "model.progress")
                ) { _ in }
            }
            Issue.record("Expected a stalled endpoint to give up, not hang")
        } catch {
            guard let exhausted = error as? DownloadRetryExhaustedError else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(exhausted.attempts == DownloadRetryPolicy.maximumAttempts)
            #expect(exhausted.lastFailure == .timedOut)
        }

        let elapsed = start.duration(to: clock.now)
        #expect(
            elapsed < .seconds(30),
            "the per-attempt deadline must bound a stalled endpoint, took \(elapsed)"
        )
    }

    @Test
    func completesASlowButProgressingTransfer() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 512 KiB in 64 KiB chunks with a 0.5 s pause between them: every pause is half
        // the configured 1 s stall bound, so the attempt is slow but never silent. A
        // throughput/rate bound would kill it; the silence bound must not. (The bound
        // the app ships with is `defaultAttemptStallTimeoutSeconds`, far larger — this
        // pins the *semantics* with a value small enough to test quickly.)
        let payloadByteCount: Int64 = 512 * 1024
        let server = try startServer(
            mode: "serve",
            logURL: nil,
            chunkDelay: 0.5,
            payloadSize: Int(payloadByteCount)
        )
        defer { server.process.terminate() }

        let downloader = ArtifactDownloader(
            retryDelaysSeconds: [0],
            attemptStallTimeoutSeconds: 1
        )
        let clock = ContinuousClock()
        let start = clock.now
        let downloadedURL = try await downloader.download(
            artifact: makeArtifact(
                destinationURL: root.appending(path: "model.gguf"),
                port: server.port,
                byteCount: payloadByteCount
            ),
            to: root.appending(path: "model.download"),
            resumeDataURL: root.appending(path: "model.resume"),
            progressDataURL: root.appending(path: "model.progress")
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == payloadByteCount)
        #expect(
            start.duration(to: clock.now) > .seconds(3),
            "the fixture was supposed to be slow; it finished too fast to prove anything"
        )
    }

    @Test
    func stallBoundToleratesASlowLinkWithoutLettingTheOfflineWaitGrow() {
        // The watchdog is an *inactivity* bound, and it shadows URLSession's
        // `timeoutIntervalForRequest`. Leaving it at that same 60 s made the two
        // collapse into one 60 s tolerance with no room for a congested/roaming link
        // that pauses body delivery for a minute. Reverting this to 60 must fail here.
        #expect(ArtifactDownloader.defaultAttemptStallTimeoutSeconds > 60)

        // Raising the per-attempt tolerance must not lengthen the total offline wait:
        // a parked attempt is held for the whole stall bound before it is retried, so
        // the product is the documented cap the UI relies on (~40 minutes).
        let totalParkedSeconds = DownloadRetryPolicy.offlineMaximumAttempts
            * ArtifactDownloader.defaultAttemptStallTimeoutSeconds
        #expect(
            totalParkedSeconds >= 30 * 60,
            "the network must stay reconnectable for a useful while, got \(totalParkedSeconds)s"
        )
        #expect(
            totalParkedSeconds <= 45 * 60,
            "the offline wait must stay a bounded, documented number of minutes, got \(totalParkedSeconds)s"
        )
        #expect(DownloadRetryPolicy.offlineMaximumAttempts > DownloadRetryPolicy.maximumAttempts)
    }

    @Test
    func offlineAndHardFailuresGetDifferentRetryBudgets() {
        // The offline/captive-portal class keeps waiting far longer than a broken
        // server, because the user can clear it without touching the app ...
        #expect(ArtifactDownloader.isOfflineCondition(URLError(.notConnectedToInternet)))
        #expect(ArtifactDownloader.isOfflineCondition(URLError(.secureConnectionFailed)))
        #expect(ArtifactDownloader.isOfflineCondition(URLError(.dnsLookupFailed)))
        #expect(
            ArtifactDownloader.retryBudget(for: URLError(.notConnectedToInternet)).attempts
                == DownloadRetryPolicy.offlineMaximumAttempts
        )
        // ... but a stalled/truncated stream or an HTTP status does not get that rope:
        // those endpoints are reachable, so retrying for minutes helps nobody.
        #expect(!ArtifactDownloader.isOfflineCondition(URLError(.networkConnectionLost)))
        #expect(!ArtifactDownloader.isOfflineCondition(URLError(.timedOut)))
        #expect(
            !ArtifactDownloader.isOfflineCondition(
                RetryableHTTPError(statusCode: 503, retryAfterSeconds: nil)
            )
        )
        #expect(
            ArtifactDownloader.retryBudget(
                for: RetryableHTTPError(statusCode: 503, retryAfterSeconds: nil)
            ).attempts == DownloadRetryPolicy.maximumAttempts
        )

        // The longer wait is still a hard bound, so `download()` always returns.
        #expect(DownloadRetryPolicy.offlineMaximumAttempts > DownloadRetryPolicy.maximumAttempts)
        #expect(DownloadRetryPolicy.offlineMaximumElapsedSeconds > 0)
    }

    @Test
    func clampsRetryAfterIntoABand() throws {
        func delay(_ value: String) throws -> Int? {
            let response = try #require(
                HTTPURLResponse(
                    url: URL(string: "https://example.invalid/model")!,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Retry-After": value]
                )
            )
            return DownloadTaskDelegate.retryAfterSeconds(from: response)
        }

        // `Retry-After: 0` must not become a zero-delay request loop.
        #expect(try delay("0") == DownloadRetryPolicy.minimumDelaySeconds)
        #expect(try delay("-5") == DownloadRetryPolicy.minimumDelaySeconds)
        // A normal value is honoured.
        #expect(try delay("7") == 7)
        // A far-future date must not become a ~7980-year sleep.
        #expect(
            try delay("Fri, 31 Dec 9999 23:59:59 GMT") == DownloadRetryPolicy.maximumDelaySeconds
        )
        #expect(try delay("999999999") == DownloadRetryPolicy.maximumDelaySeconds)
        #expect(try delay("not-a-value") == nil)

        // The downloader clamps again when it turns the hint into a sleep.
        #expect(
            ArtifactDownloader.retryDelaySeconds(
                for: RetryableHTTPError(statusCode: 503, retryAfterSeconds: 0),
                attempt: 0,
                scheduledDelays: [1, 2, 4]
            ) == DownloadRetryPolicy.minimumDelaySeconds
        )
        #expect(
            ArtifactDownloader.retryDelaySeconds(
                for: RetryableHTTPError(statusCode: 503, retryAfterSeconds: 999_999_999),
                attempt: 0,
                scheduledDelays: [1, 2, 4]
            ) == DownloadRetryPolicy.maximumDelaySeconds
        )
    }

    // MARK: - Resume validates content identity, not just the offset

    @Test
    func resumeRestartsWhenTheRemoteObjectChanged() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "change_content", logURL: logURL)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        // A stale revision-1 prefix plus the validator of the object it came from.
        let seeded: Int64 = 2 * 1_048_576
        try v1Bytes(count: Int(seeded)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: seeded, validator: nil), to: progressURL)
        try DownloadProgressCheckpoint().writeResumeMarker(
            DownloadProgressCheckpoint.ResumeMarker(
                bytes: seeded,
                validator: "\"launcher27b-robustness-fixture-v1\""
            ),
            to: progressURL
        )

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: resumeMarkerURL,
            progressDataURL: progressURL
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        let handle = try FileHandle(forReadingFrom: downloadedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        #expect(
            prefix == v2Bytes(count: 256),
            "a spliced file would still carry the stale revision-1 prefix"
        )

        // The conditional request really was made, so the server had a chance to say
        // "the object changed".
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("If-Range:\"launcher27b-robustness-fixture-v1\""))
    }

    @Test
    func resumeWithoutAStoredValidatorRestartsFromZeroInsteadOfSplicing() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "change_content", logURL: logURL)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        // Bytes on disk with no validator to tie them to the remote object (a
        // crash before the response headers were known).
        let seeded: Int64 = 2 * 1_048_576
        try v1Bytes(count: Int(seeded)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: seeded, validator: nil), to: progressURL)

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: root.appending(path: "model.resume"),
            progressDataURL: progressURL
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        let handle = try FileHandle(forReadingFrom: downloadedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        #expect(prefix == v2Bytes(count: 256), "unverifiable bytes must not be resumed onto")

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!log.contains("Range:bytes="), "a from-zero restart must not send a Range header")
    }

    @Test
    func crashResumeRestartsWhenTheRemoteObjectChanged() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "change_content", logURL: logURL)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        // The crash state: a revision-1 prefix plus a *progress checkpoint* carrying
        // revision 1's validator (written by the once-a-second tick), and no resume
        // marker, because no completion callback ever ran.
        let seeded: Int64 = 2 * 1_048_576
        try v1Bytes(count: Int(seeded)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(
            DownloadProgressCheckpoint.ResumeMarker(
                bytes: seeded,
                validator: Self.fixtureETag
            ),
            to: progressURL
        )
        #expect(!FileManager.default.fileExists(atPath: resumeMarkerURL.path))

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: resumeMarkerURL,
            progressDataURL: progressURL
        ) { _ in }

        // The anti-splice guarantee must survive the new crash-resume path: a changed
        // remote object restarts instead of appending revision 2 to revision 1.
        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        let handle = try FileHandle(forReadingFrom: downloadedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        #expect(
            prefix == v2Bytes(count: 256),
            "a spliced file would still carry the stale revision-1 prefix"
        )

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("If-Range:\(Self.fixtureETag)"))
        #expect(log.contains("Range:bytes=\(seeded)-"))
    }

    @Test
    func rejectsWeakETagsWithoutInventingAStrongValidator() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/model")!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "W/\"abc\""]
            )
        )
        #expect(DownloadTaskDelegate.validator(from: response) == nil)
        let dateOnly = try #require(HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"]))
        #expect(DownloadTaskDelegate.validator(from: dateOnly) == nil)
    }

    @Test
    func refusesA206ThatCarriesNoValidatorToCompareAgainst() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appending(path: "server.log")
        let server = try startServer(mode: "no_validator_206", logURL: logURL)
        defer { server.process.terminate() }

        let partialURL = root.appending(path: "model.download")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let artifact = makeArtifact(
            destinationURL: root.appending(path: "model.gguf"),
            port: server.port
        )

        // A stored prefix that does *not* match the server's payload, plus the
        // validator it was stored with. The fixture honours the Range (a 206 from the
        // requested offset) but sends no `ETag`/`Last-Modified` at all and ignores
        // `If-Range`, so the client has nothing to tie the slice to the stored bytes.
        // Accepting the append would splice the prefix onto the payload and call it a
        // successful download.
        let seeded: Int64 = 2 * 1_048_576
        try Data(repeating: 0xCD, count: Int(seeded)).write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(
            .init(bytes: seeded, validator: Self.fixtureETag),
            to: progressURL
        )

        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: partialURL,
            resumeDataURL: resumeMarkerURL,
            progressDataURL: progressURL
        ) { _ in }

        #expect(try fileSize(at: downloadedURL) == Self.payloadByteCount)
        let handle = try FileHandle(forReadingFrom: downloadedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        #expect(
            prefix == v1Bytes(count: 256),
            "an unverifiable 206 was appended to instead of restarting from zero"
        )

        let log = try String(contentsOf: logURL, encoding: .utf8)
        // The conditional request really was made first ...
        #expect(log.contains("If-Range:\(Self.fixtureETag)"))
        // ... and the refusal turned into a clean from-zero restart that carried no
        // range at all, rather than an append at the requested offset.
        #expect(
            log.contains("Range:-"),
            "the retry after refusing the 206 must not carry a Range header"
        )
    }

    // MARK: - A preserved download survives the retry path

    @Test
    func retryKeepsThePreservedDownloadUntilExplicitlyConfirmed() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // The explicit third retry does reach the network; a local fixture keeps it
        // fast and off the public internet. Its 8 MB `Content-Length` does not match
        // the 4 KB artifact, so the attempted download fails immediately.
        let server = try startServer(mode: "truncate_body_200", logURL: nil)
        defer { server.process.terminate() }

        let config = makeConfig(root: root)
        let goodContents = Data(repeating: 0x11, count: 4096)
        let badContents = Data(repeating: 0x22, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(server.port)/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(goodContents.count),
            expectedSHA256: sha256Hex(of: goodContents),
            kind: .file
        )

        let downloadsDirectory = config.downloadsDirectory
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = downloadsDirectory.appending(path: "model.download")
        let corruptMarkerURL = downloadsDirectory.appending(path: "model.corrupt")
        try badContents.write(to: partialURL)
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 4096, validator: nil), to: config.progressDataURL(for: .model))
        try DownloadProgressCheckpoint().writeResumeMarker(.init(bytes: 4096, validator: nil), to: config.resumeDataURL(for: .model))

        let installer = BonsaiInstaller(
            config: config,
            downloader: ArtifactDownloader(retryDelaysSeconds: [0])
        )
        do {
            try await installer.install(artifacts: [artifact]) { _ in }
            Issue.record("Expected a checksum mismatch")
        } catch {
            guard case .checksumMismatch = (error as? InstallerError) else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: corruptMarkerURL.path))

        // The retry path the error message invites the user to click must keep the
        // bytes the message promised to keep, and stop rather than silently
        // re-downloading another 7.2 GB.
        var retryError: Error?
        do {
            try await installer.install(artifacts: [artifact]) { _ in }
        } catch {
            retryError = error
        }
        #expect(retryError as? InstallerError == .checksumMismatch(component: .model))
        #expect(FileManager.default.fileExists(atPath: partialURL.path))
        #expect(FileManager.default.fileExists(atPath: config.progressDataURL(for: .model).path))
        #expect(FileManager.default.fileExists(atPath: config.resumeDataURL(for: .model).path))

        // Only a further, explicit retry discards the known-bad bytes.
        _ = try? await installer.install(artifacts: [artifact]) { _ in }
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: corruptMarkerURL.path))
    }

    // MARK: - Error mapping and classification

    @Test
    func mapsProxyAndCDNFailuresToLocalizedMessages() async throws {
        // Every code `userFacingError` claims to map, not a sample of three.
        let failures: [URLError.Code] = [
            .badServerResponse,
            .cannotParseResponse,
            .zeroByteResource,
            .cannotDecodeRawData,
            .cannotDecodeContentData,
            .badURL,
            .unsupportedURL,
            .redirectToNonExistentLocation,
        ]
        for code in failures {
            let mapped = ArtifactDownloader.userFacingError(for: URLError(code))
            #expect(
                mapped as? ArtifactDownloadError == .invalidResponse,
                "URLError \(code) must map to a localized invalid-response error"
            )
            // The mapped error is localizable, so `ServiceController`'s "操作未完成：%@"
            // fallback (which interpolates the OS-language `localizedDescription`) is
            // never reached for it.
            #expect(mapped is any AppLocalizableError)
        }

        let mapped = ArtifactDownloader.userFacingError(for: URLError(.badServerResponse))
        let rendered = await renderedMessage(for: mapped)
        #expect(!rendered.contains("The operation"))
        #expect(!rendered.contains("NSURLErrorDomain"))
        #expect(!rendered.contains("error 1011"))
    }

    @Test
    func redirectFailuresAreClassifiedWithoutDiscardingThePartial() {
        let redirect = URLError(.redirectToNonExistentLocation)

        #expect(!ArtifactDownloader.isRetryable(redirect))
        #expect(
            ArtifactDownloader.userFacingError(for: redirect) as? ArtifactDownloadError
                == .invalidResponse
        )
        // -1010 says nothing about the bytes on disk, so it must not cost the user a
        // multi-hour partial by deleting it.
        #expect(!ArtifactDownloader.discardsPartialFile(for: redirect))
        #expect(!ArtifactDownloader.discardsPartialFile(for: ArtifactDownloadError.incompleteDownload))

        // Only a content-position mismatch may discard the partial file.
        #expect(ArtifactDownloader.discardsPartialFile(for: DownloadRecoverySignal.restartFromZero))
    }

    @Test
    func theDeletionSitePreservesThePartialForTransportFailures() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let partialURL = root.appending(path: "model.download")
        let progressURL = root.appending(path: "model.progress")
        let resumeMarkerURL = root.appending(path: "model.resume")
        let downloader = ArtifactDownloader()

        func seed() throws {
            try Data(repeating: 0xAB, count: 4096).write(to: partialURL)
            try DownloadProgressCheckpoint().writeResumeMarker(
                .init(bytes: 4096, validator: "\"v1\""),
                to: progressURL
            )
            try DownloadProgressCheckpoint().writeResumeMarker(
                .init(bytes: 4096, validator: "\"v1\""),
                to: resumeMarkerURL
            )
        }

        // Assert through the actual deletion site (`handleFailedAttempt`), not the
        // classifier in isolation, to verify transport errors preserve partial files.
        try seed()
        #expect(
            try !downloader.handleFailedAttempt(
                URLError(.redirectToNonExistentLocation),
                destinationURL: partialURL,
                progressDataURL: progressURL,
                resumeDataURL: resumeMarkerURL
            )
        )
        #expect(FileManager.default.fileExists(atPath: partialURL.path))
        #expect(FileManager.default.fileExists(atPath: progressURL.path))
        #expect(FileManager.default.fileExists(atPath: resumeMarkerURL.path))

        try seed()
        #expect(
            try !downloader.handleFailedAttempt(
                ArtifactDownloadError.incompleteDownload,
                destinationURL: partialURL,
                progressDataURL: progressURL,
                resumeDataURL: resumeMarkerURL
            )
        )
        #expect(FileManager.default.fileExists(atPath: partialURL.path))

        // The one signal that does invalidate the bytes still deletes them.
        #expect(
            try downloader.handleFailedAttempt(
                DownloadRecoverySignal.restartFromZero,
                destinationURL: partialURL,
                progressDataURL: progressURL,
                resumeDataURL: resumeMarkerURL
            )
        )
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: progressURL.path))
        #expect(!FileManager.default.fileExists(atPath: resumeMarkerURL.path))
    }

    // MARK: - Memory thresholds

    @Test
    func memoryAssessmentWarnsAboutRunnableMachinesAndRefusesTheRest() {
        let gib: UInt64 = 1_073_741_824

        func assessment(_ bytes: UInt64) -> HardwareAssessment {
            HardwareRequirements(architecture: "arm64", physicalMemoryBytes: bytes).assessment
        }

        // The floor itself is allowed (with a warning): refusing it would refuse a
        // machine that can still run the model.
        if case .warning = assessment(16 * gib) {
            // expected
        } else {
            Issue.record("16 GiB must warn, got \(assessment(16 * gib))")
        }
        // 24 GiB is inside the honest working set plus macOS headroom: warned, not refused.
        if case .warning = assessment(24 * gib) {
            // expected
        } else {
            Issue.record("24 GiB must warn, got \(assessment(24 * gib))")
        }
        #expect(assessment(32 * gib) == .satisfied)
        #expect(assessment(64 * gib) == .satisfied)

        let justBelowFloor = 16 * gib - 1
        #expect(
            assessment(justBelowFloor) == .unsatisfied(
                .insufficientMemory(
                    requiredBytes: HardwareRequirements.minimumPhysicalMemoryBytes,
                    availableBytes: justBelowFloor
                )
            )
        )

        // The documented budget must stay consistent with the thresholds it justifies.
        #expect(
            HardwareRequirements.estimatedModelWorkingSetBytes
                <= HardwareRequirements.minimumPhysicalMemoryBytes
        )
        #expect(
            HardwareRequirements.recommendedPhysicalMemoryBytes
                - HardwareRequirements.estimatedModelWorkingSetBytes
                >= 16 * gib
        )
    }

    // MARK: - The rename swap never loses the download

    @Test
    func failedRenameSwapKeepsTheDownloadAndRestoresThePreviousFile() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let previousContents = Data(repeating: 0x07, count: 4096)
        let newContents = Data(repeating: 0x08, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(newContents.count),
            expectedSHA256: sha256Hex(of: newContents),
            kind: .file
        )

        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = config.downloadsDirectory.appending(path: "model.download")
        try newContents.write(to: partialURL)
        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try previousContents.write(to: config.modelFile)

        // The mid-swap failure: the previous file is moved aside, then the new file
        // cannot land. This is the window the old `replaceItemAt` sequence could not
        // recover from (both the source and the incoming file could be gone).
        let installer = BonsaiInstaller(
            config: config,
            volumeIdentity: { _ in 1 },
            renameSwapOverride: { _, destination, backup in
                guard let backup else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: destination, to: backup)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        do {
            try await installer.install(artifacts: [artifact]) { _ in }
            Issue.record("Expected the sabotaged swap to fail")
        } catch {
            // expected
        }

        #expect(try Data(contentsOf: config.modelFile) == previousContents)
        #expect(try Data(contentsOf: partialURL) == newContents)
    }

    @Test
    func sweepRestoresTheFileASwapLeftInTheBackup() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let previousContents = Data(repeating: 0x09, count: 4096)
        let newContents = Data(repeating: 0x0A, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(newContents.count),
            expectedSHA256: sha256Hex(of: newContents),
            kind: .file
        )

        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try newContents.write(to: config.downloadsDirectory.appending(path: "model.download"))
        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Crash between "move the previous file aside" and "move the new file in".
        try previousContents.write(to: BonsaiInstaller.backupURL(for: config.modelFile))

        let installer = BonsaiInstaller(config: config)
        try await installer.sweepStaleStagingEntries(for: [artifact])

        #expect(FileManager.default.fileExists(atPath: config.modelFile.path))
        #expect(try Data(contentsOf: config.modelFile) == previousContents)
        // The download is untouched, so the retry does not start over.
        #expect(
            try Data(contentsOf: config.downloadsDirectory.appending(path: "model.download"))
                == newContents
        )
        #expect(!FileManager.default.fileExists(atPath: BonsaiInstaller.backupURL(for: config.modelFile).path))
    }

    @Test
    func sweepDropsTheBackupLeftAfterASuccessfulSwap() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: 4096,
            expectedSHA256: sha256Hex(of: Data(repeating: 0x0B, count: 4096)),
            kind: .file
        )
        let installedContents = Data(repeating: 0x0B, count: 4096)

        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try installedContents.write(to: config.modelFile)
        // Crash after the new file landed but before the replaced file was dropped.
        let backupURL = BonsaiInstaller.backupURL(for: config.modelFile)
        try Data(repeating: 0x0C, count: 4096).write(to: backupURL)

        let installer = BonsaiInstaller(config: config)
        try await installer.sweepStaleStagingEntries(for: [artifact])

        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try Data(contentsOf: config.modelFile) == installedContents)
    }

    // MARK: - Volume capacity (non-boot destinations)



    @Test
    func readsRealCapacityFromARealNonBootVolume() throws {
        let volume = try Self.mountSparseVolume(label: "capacity", size: "256m")
        defer { Self.unmount(volume) }

        // The real probe, not an injected number: the bug only shows on a real volume.
        let available = try ArtifactDownloader.availableCapacity(at: volume.mountPoint)
        #expect(
            available > 0,
            "a real non-boot volume must report real free space, got \(available as Any)"
        )
    }

    @Test
    func installsToARealNonBootVolumeWithAmpleSpace() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let volume = try Self.mountSparseVolume(label: "install", size: "2g")
        defer { Self.unmount(volume) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x5A, count: 8192)
        let destinationURL = volume.mountPoint.appending(path: "models/27B/model.gguf")
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: destinationURL,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )

        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(to: config.downloadsDirectory.appending(path: "model.download"))

        let installer = BonsaiInstaller(config: config)
        #expect(!(try await installer.isSameVolume(
            config.downloadsDirectory.appending(path: "model.download"),
            destinationURL
        )))
        // Before the fix this threw "insufficient disk space: available Zero kB" on a
        // volume with ~2 GB free, because only the important-usage key was read.
        try await installer.install(artifacts: [artifact]) { _ in }

        #expect(try Data(contentsOf: destinationURL) == contents)
    }

    @Test
    func refusesToInstallWhenTheVolumeCapacityCannotBeRead() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x5B, count: 8192)
        // A cross-volume install, so the destination volume really is checked.
        let destinationURL = root.appending(path: "other-volume/models/27B/model.gguf")
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: destinationURL,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(to: config.downloadsDirectory.appending(path: "model.download"))

        let installer = BonsaiInstaller(
            config: config,
            volumeIdentity: { url in url.path.contains("other-volume") ? 2 : 1 },
            availableCapacity: { _ in throw CocoaError(.fileReadUnknown) }
        )

        do {
            try await installer.install(artifacts: [artifact]) { _ in }
            Issue.record("an unreadable volume capacity silently skipped validation")
        } catch {
            // Fail closed: the install stops instead of assuming there is room.
            guard case .fileOperationFailed = (error as? InstallerError) else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // MARK: - Staging sweep never deletes the last copy

    @Test
    func sweepKeepsThePreviousFileWhenTheRestoreFails() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: 4096,
            expectedSHA256: sha256Hex(of: Data(repeating: 0x5C, count: 4096)),
            kind: .file
        )

        try FileManager.default.createDirectory(
            at: config.modelFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previousContents = Data(repeating: 0x5D, count: 4096)
        let backupURL = BonsaiInstaller.backupURL(for: config.modelFile)
        try previousContents.write(to: backupURL)

        // The restore target exists as a dangling symlink: `fileExists` reports false
        // (so the restore is attempted) while the move itself fails. That is the
        // deterministic stand-in for "the previous file cannot be put back".
        try FileManager.default.createSymbolicLink(
            at: config.modelFile,
            withDestinationURL: root.appending(path: "missing-target")
        )
        #expect(!FileManager.default.fileExists(atPath: config.modelFile.path))

        let installer = BonsaiInstaller(config: config)
        await #expect(throws: (any Error).self) { try await installer.sweepStaleStagingEntries(for: [artifact]) }

        // The `.previous` file is the only copy of the previously installed model; a
        // failed restore must not let the removal loop delete it.
        #expect(
            FileManager.default.fileExists(atPath: backupURL.path),
            "the sweep deleted the only copy of the previously installed model"
        )
        #expect(try Data(contentsOf: backupURL) == previousContents)
    }

    // MARK: - Preserved-download hashing is not repeated

    @Test
    func discardingKnownBadPreservedBytesDoesNotHashThemFirst() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "html200", logURL: nil)
        defer { server.process.terminate() }

        let config = makeConfig(root: root)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(server.port)/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: 4096,
            expectedSHA256: sha256Hex(of: Data(repeating: 0x5E, count: 4096)),
            kind: .file
        )
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = config.downloadsDirectory.appending(path: "model.download")
        try Data(repeating: 0x5F, count: 4096).write(to: partialURL)
        // The user already retried once and confirmed the discard.
        try JSONSerialization.data(withJSONObject: ["checksum": artifact.expectedSHA256, "awaitingDiscardConfirmation": true]).write(
            to: config.downloadsDirectory.appending(path: "model.corrupt")
        )

        let counter = HashCounter()
        let installer = BonsaiInstaller(config: config, checksumComputer: counter.computer())
        _ = try? await installer.install(artifacts: [artifact]) { _ in }

        #expect(
            counter.value == 0,
            "bytes about to be discarded were hashed \(counter.value) time(s)"
        )
    }

    @Test
    func repairedPreservedBytesAreHashedExactlyOnce() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let contents = Data(repeating: 0x60, count: 4096)
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:1/model.gguf")!,
            destinationURL: config.modelFile,
            expectedByteCount: Int64(contents.count),
            expectedSHA256: sha256Hex(of: contents),
            kind: .file
        )
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try contents.write(to: config.downloadsDirectory.appending(path: "model.download"))
        try JSONSerialization.data(withJSONObject: ["checksum": artifact.expectedSHA256, "awaitingDiscardConfirmation": false]).write(
            to: config.downloadsDirectory.appending(path: "model.corrupt")
        )

        let counter = HashCounter()
        let installer = BonsaiInstaller(config: config, checksumComputer: counter.computer())
        try await installer.install(artifacts: [artifact]) { _ in }

        #expect(try Data(contentsOf: config.modelFile) == contents)
        // One hash to re-verify the preserved bytes; the install must not stream them
        // a second time.
        #expect(counter.value == 1, "expected exactly one hash, saw \(counter.value)")
    }

    @Test
    func inFlightCheckpointWriteFailureAbortsTheDownload() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try startServer(mode: "serve", logURL: nil, chunkDelay: 0.08)
        defer { server.process.terminate() }
        let progressURL = root.appending(path: "model.progress")
        let gate = FileGate(url: progressURL)
        let partial = root.appending(path: "model.download")
        let artifact = makeArtifact(destinationURL: root.appending(path: "model.gguf"), port: server.port)
        let download = Task {
            try await ArtifactDownloader(retryDelaysSeconds: [0]).download(artifact: artifact, to: partial,
                resumeDataURL: root.appending(path: "model.resume"), progressDataURL: progressURL) { update in
                await gate.record(update)
            }
        }
        await gate.wait()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: progressURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: progressURL.path) }
        let timeout = Task { try await Task.sleep(for: .seconds(8)); download.cancel() }
        defer { timeout.cancel() }
        do { _ = try await download.value; Issue.record("Checkpoint write failure reported download success") }
        catch { #expect(!ServiceController.isInstallationCancellation(error)) }
        #expect(try fileSize(at: partial) > 0)
        #expect(try fileSize(at: partial) < Self.payloadByteCount)
    }

    // MARK: - Fixtures and helpers

    private struct RawServerError: Error {}

    private actor DownloadObservation {
        private(set) var sawWaitingForNetwork = false
        private(set) var sawResuming = false

        func record(_ update: ArtifactDownloadUpdate) {
            switch update.state {
            case .waitingForNetwork:
                sawWaitingForNetwork = true
            case let .downloading(isResuming):
                if isResuming {
                    sawResuming = true
                }
            }
        }
    }

    private actor PhaseRecorder {
        private(set) var phases: [InstallationPhase] = []

        func record(_ phase: InstallationPhase) {
            if phases.last != phase {
                phases.append(phase)
            }
        }
    }

    /// Resolves once the downloader has written `url` to disk.
    ///
    /// The once-a-second progress checkpoint is the crash-survivable state, so waiting
    /// for it (rather than for a byte threshold) makes the force-quit test's timing
    /// deterministic instead of racing the progress tick.
    private actor FileGate {
        private let url: URL
        private var reached = false

        init(url: URL) {
            self.url = url
        }

        func record(_ update: ArtifactDownloadUpdate) {
            guard !reached, FileManager.default.fileExists(atPath: url.path) else { return }
            reached = true
        }

        func wait() async {
            let deadline = Date().addingTimeInterval(30)
            while !reached, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private struct TestDeadlineExceeded: Error {}

    /// Runs `operation` with a deadline so a stalled asynchronous operation fails
    /// without hanging the whole suite.
    private func withTestDeadline<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TestDeadlineExceeded()
            }
            guard let result = try await group.next() else {
                throw TestDeadlineExceeded()
            }
            group.cancelAll()
            return result
        }
    }

    /// Thread-safe call counter for the injected checksum computer.
    private final class HashCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func computer() -> BonsaiInstaller.ChecksumComputer {
            { url in
                self.lock.withLock { self.count += 1 }
                return try FileChecksum().sha256(at: url)
            }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    // MARK: - Mounted non-boot volume fixture

    private struct MountedVolume {
        let mountPoint: URL
        let workDirectory: URL
    }

    /// Runs a tool to completion with a watchdog, so `hdiutil` blocked on disk
    /// arbitration can never hang the suite.
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
                domain: "InstallerRobustnessTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(executable) timed out"]
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "InstallerRobustnessTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"]
            )
        }
    }

    private static func mountSparseVolume(
        label: String,
        size: String,
        fileSystem: String = "APFS"
    ) throws -> MountedVolume {
        let work = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-installer-mount-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let image = work.appending(path: "volume.sparseimage")
        let mountPoint = work.appending(path: "mnt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            let volumeName = "L27B-i-\(label)-\(UUID().uuidString.prefix(8))"
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

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-robustness-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeArtifact(
        destinationURL: URL,
        port: Int,
        byteCount: Int64 = InstallerRobustnessTests.payloadByteCount
    ) -> InstallationArtifact {
        InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(port)/model.gguf")!,
            destinationURL: destinationURL,
            expectedByteCount: byteCount,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )
    }

    private func makeConfig(root: URL) -> LauncherConfig {
        LauncherConfig(
            serverBinary: root.appending(path: "runtime/mac/llama-server"),
            modelFile: root.appending(path: "models/27B/Ternary-Bonsai-2-27B-PQ2_0.gguf"),
            projectorFile: root.appending(path: "models/27B/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"),
            ablationAdapterFile: root.appending(path: "modules/orcabonsai/bonsai-abliterate-lora.gguf"),
            webUIConfigFile: root.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: root.appending(path: "logs")
        )
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Fixture revision 1 (`robustness_probe_server.chunk_at` from offset 0).
    private func v1Bytes(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 256) })
    }

    /// Fixture revision 2 (`robustness_probe_server.chunk_v2_at`): same shape, inverted.
    private func v2Bytes(count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 % 256) ^ 0xFF) })
    }

    private func requestCount(in logURL: URL) throws -> Int {
        try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains("GET ") }
            .count
    }

    @MainActor
    private func renderedMessage(for error: Error) -> String {
        let suiteName = "Launcher27BTests.InstallerRobustness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        guard let localizable = error as? any AppLocalizableError else {
            // Mirrors `ServiceController.systemErrorMessage`'s last-resort fallback,
            // which renders the OS-language `NSError` text.
            return (error as NSError).localizedDescription
        }
        return localizable.localizedDescription(using: preferences)
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rangeStarts(in log: String) -> [Int64] {
        log.split(separator: "\n").compactMap { line -> Int64? in
            guard let marker = line.range(of: "Range:bytes=") else { return nil }
            let digits = line[marker.upperBound...].prefix { $0.isNumber }
            return Int64(digits)
        }
    }

    private func startServer(
        mode: String,
        logURL: URL?,
        chunkDelay: Double? = nil,
        payloadSize: Int? = nil
    ) throws -> (process: Process, port: Int) {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/robustness_probe_server.py")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        var arguments = [
            fixture.path,
            "--mode", mode,
            "--port", "0",
            "--log", logURL?.path ?? ""
        ]
        if let chunkDelay {
            arguments.append(contentsOf: ["--chunk-delay", String(chunkDelay)])
        }
        if let payloadSize {
            arguments.append(contentsOf: ["--payload-size", String(payloadSize)])
        }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()

        let data = output.fileHandleForReading.availableData
        guard let line = String(data: data, encoding: .utf8),
              let actualPort = Int(line.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile)
        }
        return (process, actualPort)
    }
}
