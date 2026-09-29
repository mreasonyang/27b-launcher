import Foundation

/// The current JSON record is the only source of download progress.
/// A missing record means no checkpoint; an unreadable or malformed record is an error.
struct DownloadProgressCheckpoint: Sendable {
    struct ResumeMarker: Codable, Sendable, Equatable {
        var bytes: Int64
        var validator: String?
    }

    func read(from url: URL) throws -> Int64 { try readResumeMarker(from: url).bytes }

    func readResumeMarker(from url: URL) throws -> ResumeMarker {
        guard try ManagedFileSystem.metadata(at: url) != nil else { return ResumeMarker(bytes: 0, validator: nil) }
        let marker = try JSONDecoder().decode(ResumeMarker.self, from: Data(contentsOf: url))
        guard marker.bytes >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        return marker
    }

    func writeResumeMarker(_ marker: ResumeMarker, to url: URL) throws {
        guard marker.bytes >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        if marker.bytes == 0 { try remove(at: url); return }
        let data = try JSONEncoder().encode(marker)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func remove(at url: URL) throws { try ManagedFileSystem.removeIfPresent(url) }

    func resumeOffset(partialURL: URL, progressDataURL: URL, expectedByteCount: Int64) throws -> Int64 {
        let marker = try readResumeMarker(from: progressDataURL)
        guard let fileBytes = try ManagedFileSystem.fileSize(at: partialURL) else {
            guard marker.bytes == 0 else { throw CocoaError(.fileReadCorruptFile) }
            return 0
        }
        guard fileBytes <= expectedByteCount, marker.bytes <= fileBytes else { throw CocoaError(.fileReadCorruptFile) }
        // No checkpoint is a new attempt. An existing malformed record never reaches here.
        return marker.bytes
    }
}
