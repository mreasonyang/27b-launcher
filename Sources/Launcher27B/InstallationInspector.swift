import Foundation

/// Outcome of a full-content verification of an installed artifact.
enum ArtifactVerification: Sendable, Equatable {
    case verified
    case missing
    case sizeMismatch(expected: Int64, actual: Int64?)
    case checksumMismatch
    /// The artifact is validated structurally (release marker + binaries) instead of by digest.
    case notDigestVerifiable
}

struct InstallationInspector: Sendable {
    func missingArtifacts(
        from artifacts: [InstallationArtifact],
        config: LauncherConfig
    ) throws -> [InstallationArtifact] {
        try artifacts.filter { try !isInstalled($0, config: config) }
    }

    /// Structural "is it on disk?" check. A `.file` artifact is accepted on size alone,
    /// which is cheap but cannot detect bit-rot or a truncated-but-resized file.
    func isInstalled(
        _ artifact: InstallationArtifact,
        config: LauncherConfig
    ) throws -> Bool {
        switch artifact.kind {
        case .file:
            return try fileSize(at: artifact.destinationURL) == artifact.expectedByteCount

        case let .runtimeArchive(releaseMarker):
            let runtimeDirectory = artifact.destinationURL
            let markerURL = runtimeDirectory.appending(path: ".llama_release")
            let serverURL = runtimeDirectory.appending(path: "llama-server")
            let serverLibraryURL = runtimeDirectory.appending(path: "libllama-server-impl.dylib")

            guard FileManager.default.isExecutableFile(atPath: serverURL.path),
                  FileManager.default.fileExists(atPath: serverLibraryURL.path),
                  try ManagedFileSystem.metadata(at: markerURL) != nil
            else {
                return false
            }

            let marker = try String(contentsOf: markerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return marker == releaseMarker && serverURL == config.serverBinary
        }
    }

    /// Artifacts that are present but whose contents were never digested on this Mac.
    ///
    /// `isInstalled` only compares byte counts for `.file` artifacts, so this is the set
    /// a "verify installation" pass should hash to rule out corruption.
    func artifactsRequiringVerification(
        from artifacts: [InstallationArtifact],
        config: LauncherConfig
    ) throws -> [InstallationArtifact] {
        try artifacts.filter { artifact in
            guard case .file = artifact.kind else { return false }
            return try isInstalled(artifact, config: config)
        }
    }

    func requiresVerification(
        _ artifact: InstallationArtifact,
        config: LauncherConfig
    ) throws -> Bool {
        guard case .file = artifact.kind else { return false }
        return try isInstalled(artifact, config: config)
    }

    /// Full-content verification. Computes the SHA-256 of `.file` artifacts; runtime
    /// archives are checked structurally. Cancellation-aware via `FileChecksum`.
    func verify(
        _ artifact: InstallationArtifact,
        config: LauncherConfig,
        checksum: FileChecksum = FileChecksum()
    ) async throws -> ArtifactVerification {
        switch artifact.kind {
        case .file:
            let actualSize = try fileSize(at: artifact.destinationURL)
            guard let actualSize else { return .missing }
            guard actualSize == artifact.expectedByteCount else {
                return .sizeMismatch(expected: artifact.expectedByteCount, actual: actualSize)
            }
            let actualChecksum = try checksum.sha256(at: artifact.destinationURL)
            return actualChecksum == artifact.expectedSHA256 ? .verified : .checksumMismatch

        case .runtimeArchive:
            return try isInstalled(artifact, config: config) ? .notDigestVerifiable : .missing
        }
    }

    private func fileSize(at url: URL) throws -> Int64? { try ManagedFileSystem.fileSize(at: url) }
}
