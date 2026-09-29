import Foundation

actor BonsaiInstaller {
    /// Maps a path to the identity of the volume that hosts it.
    ///
    /// Injectable so the cross-volume transfer path can be exercised in tests without
    /// a second real volume; production always uses `systemVolumeIdentity`.
    typealias VolumeIdentityProvider = @Sendable (URL) -> UInt64?

    /// Test seam replacing the same-volume destination swap.
    ///
    /// A real mid-swap file-system failure -- the previous destination moved aside and
    /// then the new file failing to land -- cannot be provoked deterministically in a
    /// unit test, and that window is exactly what the recovery path must survive.
    /// Production leaves this `nil` so ``performRenameSwap`` runs.
    typealias RenameSwapOverride = @Sendable (_ source: URL, _ destination: URL, _ backup: URL?) throws -> Void

    /// Test seam replacing the SHA-256 computation, so a test can prove how many
    /// times a multi-gigabyte artifact is re-hashed. Production uses `FileChecksum`.
    typealias ChecksumComputer = @Sendable (URL) throws -> String

    /// How the installer measures a volume's free space. Injectable so a test can
    /// simulate an unreadable volume deterministically.
    typealias AvailableCapacityProvider = @Sendable (URL) throws -> Int64

    private static let diskSpaceReserveBytes: Int64 = 1_073_741_824
    private static let copyChunkBytes = 4 * 1_048_576

    private let config: LauncherConfig
    private let downloader: ArtifactDownloader
    private let computeChecksum: ChecksumComputer
    private let checkpoint: DownloadProgressCheckpoint
    private let volumeIdentity: VolumeIdentityProvider
    private let renameSwapOverride: RenameSwapOverride?
    private let availableCapacity: AvailableCapacityProvider

    init(
        config: LauncherConfig,
        downloader: ArtifactDownloader = ArtifactDownloader(),
        checksum: FileChecksum = FileChecksum(),
        checkpoint: DownloadProgressCheckpoint = DownloadProgressCheckpoint(),
        volumeIdentity: @escaping VolumeIdentityProvider = { BonsaiInstaller.systemVolumeIdentity(for: $0) },
        renameSwapOverride: RenameSwapOverride? = nil,
        checksumComputer: ChecksumComputer? = nil,
        availableCapacity: @escaping AvailableCapacityProvider = {
            try BonsaiInstaller.systemAvailableCapacity(at: $0)
        }
    ) {
        self.config = config
        self.downloader = downloader
        self.computeChecksum = checksumComputer ?? { try checksum.sha256(at: $0) }
        self.checkpoint = checkpoint
        self.volumeIdentity = volumeIdentity
        self.renameSwapOverride = renameSwapOverride
        self.availableCapacity = availableCapacity
    }

    func install(
        artifacts: [InstallationArtifact],
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws {
        guard !artifacts.isEmpty else { return }

        let fileManager = FileManager.default
        let downloadsDirectory = config.downloadsDirectory
        do {
            try fileManager.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallerError.wrapping(error)
        }

        // Reclaim any hidden staging left behind by a crash before measuring free space.
        try sweepStaleStagingEntries(for: artifacts)
        try ensureDiskSpace(for: artifacts)

        let overallTotal = artifacts.reduce(Int64(0)) { partial, artifact in
            partial + artifact.expectedByteCount
        }
        var completedBeforeCurrent: Int64 = 0

        for artifact in artifacts {
            try Task.checkCancellation()

            let partialURL = downloadsDirectory.appending(
                path: "\(artifact.component.rawValue).download"
            )
            let resumeMarkerURL = config.resumeDataURL(for: artifact.component)
            let progressDataURL = config.progressDataURL(for: artifact.component)
            let corruptMarkerURL = corruptMarkerURL(for: artifact.component)

            // A previous attempt matched the expected size but failed the digest.
            // `InstallerError.checksumMismatch` promises the user those bytes are
            // kept, so this path never silently deletes them:
            //
            //  * The first time the app comes back here the preserved bytes are
            //    re-hashed -- cheap next to re-downloading ~7 GB -- and installed
            //    as-is when they now match. The result is remembered so the digest
            //    check below does not stream the same file a second time.
            //  * Otherwise the marker records that the user has been told the kept
            //    bytes are unusable, and the install stops with the same actionable
            //    error. Only an explicit *second* retry discards them and downloads
            //    again, so no single click can throw away a multi-hour download --
            //    and that discard does not re-hash bytes that are about to be deleted.
            var preservedVerified = false
            if fileManager.fileExists(atPath: corruptMarkerURL.path) {
                let marker = try readCorruptMarker(corruptMarkerURL)
                if marker.awaitingDiscardConfirmation {
                    // The user was already told the kept bytes failed verification and
                    // chose to retry once more: that is explicit consent to replace
                    // them. Skip the hash: these bytes are on their way out.
                    try ManagedFileSystem.removeIfPresent(partialURL)
                    try ManagedFileSystem.removeIfPresent(resumeMarkerURL)
                    try ManagedFileSystem.removeIfPresent(progressDataURL)
                    try ManagedFileSystem.removeIfPresent(corruptMarkerURL)
                } else {
                    let preservedDigest = try fileSize(at: partialURL) == artifact.expectedByteCount
                        ? try computeChecksum(partialURL) : nil
                    if preservedDigest == artifact.expectedSHA256 {
                        // The preserved bytes are good after all (a stale marker, or
                        // the file was repaired). Install them instead of downloading
                        // again, and reuse this digest below.
                        preservedVerified = true
                        try ManagedFileSystem.removeIfPresent(corruptMarkerURL)
                    } else {
                        try writeCorruptMarker(
                            marker.checksum,
                            awaitingDiscardConfirmation: true,
                            to: corruptMarkerURL
                        )
                        throw InstallerError.checksumMismatch(component: artifact.component)
                    }
                }
            }

            let hasReusableDownload = try fileSize(at: partialURL) == artifact.expectedByteCount
            if !hasReusableDownload {
                let completedBeforeDownload = completedBeforeCurrent
                _ = try await downloader.download(
                    artifact: artifact,
                    to: partialURL,
                    resumeDataURL: resumeMarkerURL,
                    progressDataURL: progressDataURL
                ) { update in
                    let phase: InstallationPhase
                    let isResuming: Bool
                    switch update.state {
                    case let .downloading(resuming):
                        phase = .downloading
                        isResuming = resuming
                    case .waitingForNetwork:
                        phase = .waitingForNetwork
                        isResuming = true
                    }
                    await progress(
                        InstallationProgress(
                            component: artifact.component,
                            phase: phase,
                            isResuming: isResuming,
                            componentCompletedBytes: min(update.completedBytes, update.totalBytes),
                            componentTotalBytes: update.totalBytes,
                            overallCompletedBytes: completedBeforeDownload
                                + min(update.completedBytes, update.totalBytes),
                            overallTotalBytes: overallTotal,
                            bytesPerSecond: update.bytesPerSecond,
                            estimatedTimeRemaining: update.bytesPerSecond.flatMap { speed in
                                guard speed > 0 else { return nil }
                                let completed = completedBeforeDownload
                                    + min(update.completedBytes, update.totalBytes)
                                return Double(max(overallTotal - completed, 0)) / speed
                            }
                        )
                    )
                }
            }

            try Task.checkCancellation()
            await progress(
                InstallationProgress(
                    component: artifact.component,
                    phase: .verifying,
                    isResuming: false,
                    componentCompletedBytes: artifact.expectedByteCount,
                    componentTotalBytes: artifact.expectedByteCount,
                    overallCompletedBytes: completedBeforeCurrent + artifact.expectedByteCount,
                    overallTotalBytes: overallTotal,
                    bytesPerSecond: nil,
                    estimatedTimeRemaining: nil
                )
            )

            let actualChecksum: String
            if preservedVerified {
                // Already streamed on the corrupt-marker path above; hashing 7.2 GB a
                // second time would only make the user wait again for the same answer.
                actualChecksum = artifact.expectedSHA256
            } else {
                actualChecksum = try computeChecksum(partialURL)
            }
            guard actualChecksum == artifact.expectedSHA256 else {
                // Preserve the bytes and the resume metadata. Deleting hours of user
                // bandwidth is never the right first response; `reverifyPreservedDownload`
                // gives the caller a way to re-check, and only an explicit second retry
                // discards the known-bad file before re-downloading it.
                try writeCorruptMarker(
                    actualChecksum,
                    awaitingDiscardConfirmation: false,
                    to: corruptMarkerURL
                )
                throw InstallerError.checksumMismatch(component: artifact.component)
            }
            try ManagedFileSystem.removeIfPresent(corruptMarkerURL)

            try Task.checkCancellation()

            switch artifact.kind {
            case .file:
                // `installFile` reports the `.copying` phase with progress; the copy is
                // the long part when the destination lives on another volume.
                try await installFile(
                    from: partialURL,
                    to: artifact.destinationURL,
                    component: artifact.component,
                    expectedByteCount: artifact.expectedByteCount,
                    overallCompletedBefore: completedBeforeCurrent,
                    overallTotal: overallTotal,
                    progress: progress
                )
            case let .runtimeArchive(releaseMarker):
                await progress(
                    InstallationProgress(
                        component: artifact.component,
                        phase: .installing,
                        isResuming: false,
                        componentCompletedBytes: artifact.expectedByteCount,
                        componentTotalBytes: artifact.expectedByteCount,
                        overallCompletedBytes: completedBeforeCurrent + artifact.expectedByteCount,
                        overallTotalBytes: overallTotal,
                        bytesPerSecond: nil,
                        estimatedTimeRemaining: nil
                    )
                )
                try await installRuntime(
                    from: partialURL,
                    to: artifact.destinationURL,
                    releaseMarker: releaseMarker
                )
            }

            try ManagedFileSystem.removeIfPresent(resumeMarkerURL)
            try ManagedFileSystem.removeIfPresent(progressDataURL)
            completedBeforeCurrent += artifact.expectedByteCount
        }
    }

    /// Re-verifies a partial download preserved after a checksum mismatch and installs
    /// it when the digest now matches.
    ///
    /// - Returns: `true` when the artifact verified and was installed.
    /// - Throws: `InstallerError.checksumMismatch` when the preserved bytes are still bad.
    @discardableResult
    func reverifyPreservedDownload(for artifact: InstallationArtifact) async throws -> Bool {
        let partialURL = config.downloadsDirectory.appending(
            path: "\(artifact.component.rawValue).download"
        )
        guard try fileSize(at: partialURL) == artifact.expectedByteCount else {
            throw InstallerError.sourceMissing(component: artifact.component)
        }
        let actualChecksum = try computeChecksum(partialURL)
        guard actualChecksum == artifact.expectedSHA256 else {
            try writeCorruptMarker(
                actualChecksum,
                awaitingDiscardConfirmation: false,
                to: corruptMarkerURL(for: artifact.component)
            )
            throw InstallerError.checksumMismatch(component: artifact.component)
        }

        try ManagedFileSystem.removeIfPresent(corruptMarkerURL(for: artifact.component))
        switch artifact.kind {
        case .file:
            try await installFile(
                from: partialURL,
                to: artifact.destinationURL,
                component: artifact.component,
                expectedByteCount: artifact.expectedByteCount,
                overallCompletedBefore: 0,
                overallTotal: artifact.expectedByteCount,
                progress: { _ in }
            )
        case let .runtimeArchive(releaseMarker):
            try await installRuntime(
                from: partialURL,
                to: artifact.destinationURL,
                releaseMarker: releaseMarker
            )
        }

        try ManagedFileSystem.removeIfPresent(config.resumeDataURL(for: artifact.component))
        try ManagedFileSystem.removeIfPresent(config.progressDataURL(for: artifact.component))
        return true
    }

    /// Restore only backups produced by the current transaction. Errors stop installation.
    func sweepStaleStagingEntries(for artifacts: [InstallationArtifact]) throws {
        let fm = FileManager.default
        for artifact in artifacts {
            let backup: URL
            switch artifact.kind {
            case .file: backup = Self.backupURL(for: artifact.destinationURL)
            case .runtimeArchive: backup = artifact.destinationURL.deletingLastPathComponent().appending(path: ".mac.previous")
            }
            if try ManagedFileSystem.metadata(at: backup) != nil {
                if try ManagedFileSystem.metadata(at: artifact.destinationURL) == nil {
                    try fm.moveItem(at: backup, to: artifact.destinationURL)
                } else {
                    // Never discard a backup when the current destination cannot be inspected.
                    guard try InstallationInspector().isInstalled(artifact, config: config) else {
                        throw InstallerError.sourceMissing(component: artifact.component)
                    }
                    try fm.removeItem(at: backup)
                }
            }
            if case .runtimeArchive = artifact.kind {
                try ManagedFileSystem.removeIfPresent(artifact.destinationURL.deletingLastPathComponent().appending(path: ".mac.installing"))
            }
        }
    }

    func stagingLeftoverBytes(for artifacts: [InstallationArtifact]) throws -> Int64 {
        try stagingURLs(for: artifacts).reduce(Int64(0)) { try $0 + ManagedFileSystem.allocatedBytes(at: $1) }
    }

    private var supportDirectory: URL {
        config.supportDirectory
    }

    // MARK: - Disk space

    /// Bytes that will actually be written to each volume, keyed by resolved volume path.
    ///
    /// A same-volume `.file` install is a rename, so it needs *no* destination space —
    /// only the remaining download. A cross-volume install additionally needs room for
    /// the copy on the destination volume. A runtime archive is always extracted, so it
    /// always needs destination space.
    func diskSpaceRequirements(for artifacts: [InstallationArtifact]) throws -> [URL: Int64] {
        var requirements: [URL: Int64] = [:]

        func require(_ url: URL, _ bytes: Int64) throws {
            guard bytes > 0 else { return }
            requirements[try Self.volumeRoot(for: url), default: 0] += bytes
        }

        for artifact in artifacts {
            let completedDownload = config.downloadsDirectory.appending(
                path: "\(artifact.component.rawValue).download"
            )
            let resumableBytes: Int64
            if try fileSize(at: completedDownload) == artifact.expectedByteCount {
                resumableBytes = artifact.expectedByteCount
            } else {
                resumableBytes = try checkpoint.resumeOffset(
                    partialURL: completedDownload,
                    progressDataURL: config.progressDataURL(for: artifact.component),
                    expectedByteCount: artifact.expectedByteCount
                )
            }
            try require(
                config.downloadsDirectory,
                max(artifact.expectedByteCount - resumableBytes, 0)
            )

            switch artifact.kind {
            case .file:
                if try !isSameVolume(completedDownload, artifact.destinationURL) {
                    // Cross-volume: the copy lands on the destination volume while the
                    // downloaded source still occupies the downloads volume.
                    try require(artifact.destinationURL, artifact.expectedByteCount)
                }
            case .runtimeArchive:
                try require(artifact.destinationURL, artifact.expectedByteCount)
            }
        }

        return requirements
    }

    /// Measures free space on the volumes that will actually be written to.
    ///
    /// The destination is resolved through symlinks first: after a migration the model
    /// directory is a link to an external volume, and only that volume's free space is
    /// relevant for the copy.
    private func ensureDiskSpace(for artifacts: [InstallationArtifact]) throws {
        for space in try diskSpaceReport(for: artifacts) {
            guard space.isSufficient else {
                throw InstallerError.insufficientDiskSpace(required: space.requiredBytes, available: space.availableBytes)
            }
        }
    }

    /// Shared by the pre-download UI and the final install-time check.
    func diskSpaceReport(for artifacts: [InstallationArtifact]) throws -> [InstallationVolumeSpace] {
        try diskSpaceRequirements(for: artifacts).map { volume, bytes in
            do {
                return InstallationVolumeSpace(volume: volume, requiredBytes: bytes + Self.diskSpaceReserveBytes,
                                               availableBytes: try availableCapacity(volume))
            } catch { throw InstallerError.wrapping(error) }
        }.sorted { $0.volume.path < $1.volume.path }
    }

    static func systemAvailableCapacity(at volume: URL) throws -> Int64 {
        try DiskCapacity.available(at: volume)
    }

    // MARK: - File install

    /// Puts the downloaded file in place without ever losing the source.
    ///
    /// Same volume: the transfer is an atomic rename, so no extra space is needed and no
    /// partial state can exist. Cross volume: `moveItem` would be a full copy that can
    /// lose the source, so the file is copied into a hidden staging file, verified, then
    /// swapped in, and the source is deleted only after that swap succeeds. The cross
    /// volume path reports a dedicated `.copying` phase so the UI does not sit at
    /// 100% "installing" for minutes.
    private func installFile(
        from sourceURL: URL,
        to destinationURL: URL,
        component: InstallationComponent,
        expectedByteCount: Int64,
        overallCompletedBefore: Int64,
        overallTotal: Int64,
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallerError.wrapping(error)
        }

        if try isSameVolume(sourceURL, destinationURL) {
            try await installFileByRename(
                from: sourceURL,
                to: destinationURL,
                component: component,
                expectedByteCount: expectedByteCount,
                overallCompletedBefore: overallCompletedBefore,
                overallTotal: overallTotal,
                progress: progress
            )
            return
        }

        try await installFileByCopy(
            from: sourceURL,
            to: destinationURL,
            component: component,
            expectedByteCount: expectedByteCount,
            overallCompletedBefore: overallCompletedBefore,
            overallTotal: overallTotal,
            progress: progress
        )
    }

    /// Same-volume transfer: rename, never copy.
    ///
    /// When a previous file is being replaced it is moved aside to a hidden backup
    /// first, the new file is renamed into place, and only then is the backup
    /// dropped. The downloaded source is moved exactly once, as the last step, and a
    /// rename is atomic, so no failure can leave it consumed without the bytes being
    /// present somewhere: the source is intact on a failed rename, and the previous
    /// destination is restored from the backup if the new file cannot land. A crash
    /// inside the window is covered by ``sweepStaleStagingEntries``.
    private func installFileByRename(
        from sourceURL: URL,
        to destinationURL: URL,
        component: InstallationComponent,
        expectedByteCount: Int64,
        overallCompletedBefore: Int64,
        overallTotal: Int64,
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let backupURL = Self.backupURL(for: destinationURL)

        await reportTransferProgress(
            phase: .installing,
            completedBytes: expectedByteCount,
            totalBytes: expectedByteCount,
            component: component,
            overallCompletedBefore: overallCompletedBefore,
            overallTotal: overallTotal,
            progress: progress
        )

        let hadDestination = fileManager.fileExists(atPath: destinationURL.path)
        do {
            if let renameSwapOverride {
                try renameSwapOverride(sourceURL, destinationURL, hadDestination ? backupURL : nil)
            } else {
                try Self.performRenameSwap(
                    from: sourceURL,
                    to: destinationURL,
                    backupURL: hadDestination ? backupURL : nil
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            // Exhaustive recovery: restore the previous destination if the failed
            // swap consumed it. The downloaded source needs no restoring -- it is
            // moved only by the final atomic rename, which leaves it in place when
            // it fails.
            if !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw InstallerError.wrapping(error)
        }
    }

    /// Moves `sourceURL` onto `destinationURL`, keeping any existing destination at
    /// `backupURL` until the new file is in place.
    private static func performRenameSwap(
        from sourceURL: URL,
        to destinationURL: URL,
        backupURL: URL?
    ) throws {
        let fileManager = FileManager.default
        guard let backupURL else {
            // Nothing installed yet: one rename, and a failure leaves the source alone.
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try ManagedFileSystem.removeIfPresent(backupURL)
        }
        // 1. Move the old file aside. If this fails the source is untouched.
        try fileManager.moveItem(at: destinationURL, to: backupURL)
        do {
            // 2. Move the new file in. If this fails the source is still where it was
            //    (the rename did not happen), so put the old file back.
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.moveItem(at: backupURL, to: destinationURL)
            throw error
        }
        // 3. The new file is in place; the replaced file is expendable.
        try ManagedFileSystem.removeIfPresent(backupURL)
    }

    /// Hidden backup a same-volume install keeps while it replaces an existing file.
    static func backupURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appending(
            path: ".\(destinationURL.lastPathComponent).previous"
        )
    }

    /// Cross-volume transfer: copy, verify, swap, then delete the source.
    private func installFileByCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        component: InstallationComponent,
        expectedByteCount: Int64,
        overallCompletedBefore: Int64,
        overallTotal: Int64,
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let incomingURL = destinationURL.deletingLastPathComponent().appending(
            path: ".\(destinationURL.lastPathComponent).installing"
        )
        if fileManager.fileExists(atPath: incomingURL.path) {
            try ManagedFileSystem.removeIfPresent(incomingURL)
        }

        let sourceSize = try ManagedFileSystem.requiredFileSize(at: sourceURL)
        do {
            try await copyFile(
                from: sourceURL,
                to: incomingURL,
                totalBytes: max(sourceSize, 0),
                component: component,
                overallCompletedBefore: overallCompletedBefore,
                overallTotal: overallTotal,
                progress: progress
            )
        } catch {
            try ManagedFileSystem.removeIfPresent(incomingURL)
            throw InstallerError.wrapping(error)
        }

        guard try fileSize(at: incomingURL) == sourceSize else {
            try ManagedFileSystem.removeIfPresent(incomingURL)
            throw InstallerError.fileOperationFailed(underlying: "copied size mismatch")
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: incomingURL)
            } else {
                try fileManager.moveItem(at: incomingURL, to: destinationURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            try ManagedFileSystem.removeIfPresent(incomingURL)
            throw InstallerError.wrapping(error)
        }

        // Only now is the downloaded source expendable.
        try ManagedFileSystem.removeIfPresent(sourceURL)
    }

    private func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        totalBytes: Int64,
        component: InstallationComponent,
        overallCompletedBefore: Int64,
        overallTotal: Int64,
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw InstallerError.fileOperationFailed(underlying: "cannot create staging file")
        }
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        let clock = ContinuousClock()
        var lastReportInstant = clock.now
        var copiedBytes: Int64 = 0

        await reportTransferProgress(
            phase: .copying,
            completedBytes: 0,
            totalBytes: totalBytes,
            component: component,
            overallCompletedBefore: overallCompletedBefore,
            overallTotal: overallTotal,
            progress: progress
        )

        while true {
            try Task.checkCancellation()
            let data = try sourceHandle.read(upToCount: Self.copyChunkBytes) ?? Data()
            if data.isEmpty {
                break
            }
            try destinationHandle.write(contentsOf: data)
            copiedBytes += Int64(data.count)

            let now = clock.now
            if lastReportInstant.duration(to: now) >= .milliseconds(150)
                || copiedBytes >= totalBytes {
                lastReportInstant = now
                await reportTransferProgress(
                    phase: .copying,
                    completedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    component: component,
                    overallCompletedBefore: overallCompletedBefore,
                    overallTotal: overallTotal,
                    progress: progress
                )
            }
        }

        guard copiedBytes == totalBytes else { throw InstallerError.fileOperationFailed(underlying: "Source changed during copy") }
        try destinationHandle.synchronize()
        try destinationHandle.close()
        try sourceHandle.close()
        await reportTransferProgress(
            phase: .copying,
            completedBytes: copiedBytes,
            totalBytes: totalBytes,
            component: component,
            overallCompletedBefore: overallCompletedBefore,
            overallTotal: overallTotal,
            progress: progress
        )
    }

    private func reportTransferProgress(
        phase: InstallationPhase,
        completedBytes: Int64,
        totalBytes: Int64,
        component: InstallationComponent,
        overallCompletedBefore: Int64,
        overallTotal: Int64,
        progress: @escaping @Sendable (InstallationProgress) async -> Void
    ) async {
        let completed = min(max(completedBytes, 0), max(totalBytes, 0))
        await progress(
            InstallationProgress(
                component: component,
                phase: phase,
                isResuming: false,
                componentCompletedBytes: completed,
                componentTotalBytes: totalBytes,
                overallCompletedBytes: overallCompletedBefore + completed,
                overallTotalBytes: overallTotal,
                bytesPerSecond: nil,
                estimatedTimeRemaining: nil
            )
        )
    }

    // MARK: - Runtime install

    private func installRuntime(
        from archiveURL: URL,
        to runtimeDirectory: URL,
        releaseMarker: String
    ) async throws {
        let fileManager = FileManager.default
        let parentDirectory = runtimeDirectory.deletingLastPathComponent()
        let stagingDirectory = parentDirectory.appending(path: ".mac.installing")
        let backupDirectory = parentDirectory.appending(path: ".mac.previous")

        do {
            try fileManager.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallerError.wrapping(error)
        }
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try ManagedFileSystem.removeIfPresent(stagingDirectory)
        }
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallerError.wrapping(error)
        }

        try await run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf", archiveURL.path,
                "-C", stagingDirectory.path,
                "--strip-components=1"
            ]
        )

        let stagedServer = stagingDirectory.appending(path: "llama-server")
        let stagedLibrary = stagingDirectory.appending(path: "libllama-server-impl.dylib")
        guard fileManager.fileExists(atPath: stagedServer.path),
              fileManager.fileExists(atPath: stagedLibrary.path)
        else {
            throw InstallerError.runtimeArchiveInvalid
        }

        try await run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-cr", stagingDirectory.path]
        )
        try await run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--timestamp=none", stagedServer.path]
        )
        do {
            try "\(releaseMarker)\n".write(
                to: stagingDirectory.appending(path: ".llama_release"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw InstallerError.wrapping(error)
        }

        if fileManager.fileExists(atPath: backupDirectory.path) {
            try ManagedFileSystem.removeIfPresent(backupDirectory)
        }
        do {
            if fileManager.fileExists(atPath: runtimeDirectory.path) {
                try fileManager.moveItem(at: runtimeDirectory, to: backupDirectory)
            }
        } catch {
            throw InstallerError.wrapping(error)
        }

        do {
            try fileManager.moveItem(at: stagingDirectory, to: runtimeDirectory)
            if fileManager.fileExists(atPath: backupDirectory.path) {
                try ManagedFileSystem.removeIfPresent(backupDirectory)
            }
            try ManagedFileSystem.removeIfPresent(archiveURL)
        } catch {
            if !fileManager.fileExists(atPath: runtimeDirectory.path),
               fileManager.fileExists(atPath: backupDirectory.path) {
                try fileManager.moveItem(at: backupDirectory, to: runtimeDirectory)
            }
            throw InstallerError.wrapping(error)
        }
    }

    private func run(executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallerError.commandFailed(
                        command: executable.lastPathComponent,
                        status: process.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func corruptMarkerURL(for component: InstallationComponent) -> URL {
        config.downloadsDirectory.appending(path: "\(component.rawValue).corrupt")
    }

    /// What the `.corrupt` marker records about a preserved-but-unverified download.
    private struct CorruptMarker: Codable, Sendable {
        var checksum: String
        /// `true` once the user has been shown that the preserved bytes failed
        /// verification, so the next install is a deliberate discard-and-redownload.
        var awaitingDiscardConfirmation: Bool
    }

    private func readCorruptMarker(_ url: URL) throws -> CorruptMarker {
        let marker = try JSONDecoder().decode(CorruptMarker.self, from: Data(contentsOf: url))
        guard marker.checksum.count == 64, marker.checksum.allSatisfy({ $0.isHexDigit }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return marker
    }

    private func writeCorruptMarker(_ checksum: String, awaitingDiscardConfirmation: Bool, to url: URL) throws {
        let marker = CorruptMarker(checksum: checksum, awaitingDiscardConfirmation: awaitingDiscardConfirmation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
    }

    private func stagingURLs(for artifacts: [InstallationArtifact]) -> [URL] {
        artifacts.flatMap { stagingURLs(for: $0) }
    }

    private func stagingURLs(for artifact: InstallationArtifact) -> [URL] {
        switch artifact.kind {
        case .file:
            return [
                // The replaced file, held until the new one is in place.
                Self.backupURL(for: artifact.destinationURL)
            ]
        case .runtimeArchive:
            let parent = artifact.destinationURL.deletingLastPathComponent()
            return [
                parent.appending(path: ".mac.installing"),
                parent.appending(path: ".mac.previous")
            ]
        }
    }

    /// Resolves the deepest existing ancestor of `url` through symlinks and returns it,
    /// so volume capacity is measured on the volume that actually hosts the path.
    static func volumeRoot(for url: URL) throws -> URL {
        try deepestExistingAncestor(of: url).resolvingSymlinksInPath()
    }

    /// Deepest existing ancestor of `url`, used because destination directories often do
    /// not exist yet. Symlinks ARE followed (`stat`, not `lstat`), so a migrated model
    /// directory resolves to the external volume it points at.
    static func deepestExistingAncestor(of url: URL) throws -> URL {
        var probe = url
        while try ManagedFileSystem.metadata(at: probe) == nil, probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }

    /// Device id of the volume hosting `url`, or `nil` when it cannot be determined.
    static func systemVolumeIdentity(for url: URL) -> UInt64? {
        var info = stat()
        guard let ancestor = try? deepestExistingAncestor(of: url),
              stat(ancestor.path, &info) == 0 else {
            return nil
        }
        return UInt64(info.st_dev)
    }

    /// Whether two paths live on the same volume, i.e. whether a rename is possible.
    /// Unknown volume identity is an error; it never selects another transfer method.
    func isSameVolume(_ first: URL, _ second: URL) throws -> Bool {
        guard let firstIdentity = volumeIdentity(first),
              let secondIdentity = volumeIdentity(second)
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return firstIdentity == secondIdentity
    }

    private func fileSize(at url: URL) throws -> Int64? { try ManagedFileSystem.fileSize(at: url) }
}
