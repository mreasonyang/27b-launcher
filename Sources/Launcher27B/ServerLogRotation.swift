import Darwin
import Foundation

/// Private, size-capped server logs. Every failed read, write, or rotation is reported.
struct ServerLogRotation: Sendable {
    static let defaultMaximumBytes = 4 * 1024 * 1024
    static let defaultGenerations = 3
    let maximumBytes: Int
    let generations: Int

    init(maximumBytes: Int = Self.defaultMaximumBytes, generations: Int = Self.defaultGenerations) {
        precondition(maximumBytes > 0 && generations > 0)
        self.maximumBytes = maximumBytes
        self.generations = generations
    }

    func openLog(at url: URL, header: String) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rotateIfNeeded(at: url)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError(url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError(url) }
            try handle.write(contentsOf: Data(header.utf8))
            return handle
        } catch {
            // Preserve the operation's error; this descriptor is already being discarded.
            try? handle.close()
            throw error
        }
    }

    func rotateIfNeeded(at url: URL) throws {
        guard let size = try ManagedFileSystem.fileSize(at: url), size >= maximumBytes else { return }
        try shiftGenerations(for: url)
        try FileManager.default.moveItem(at: url, to: Self.rotatedURL(for: url, generation: 1))
    }

    /// Preserve and sync the tail before truncating the live O_APPEND descriptor.
    /// A failed preservation leaves the live bytes and all existing generations intact.
    func enforceCap(at url: URL, handle: FileHandle) throws {
        let size = try ManagedFileSystem.requiredFileSize(at: url)
        guard size >= maximumBytes else { return }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        try reader.seek(toOffset: end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0)
        guard let tail = try reader.readToEnd(), !tail.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let staging = Self.preservingURL(for: url)
        try Self.writeDurably(tail, to: staging)
        try shiftGenerations(for: url)
        let destination = Self.rotatedURL(for: url, generation: 1)
        try FileManager.default.moveItem(at: staging, to: destination)
        guard fchmod(handle.fileDescriptor, 0o600) == 0 else { throw posixError(url) }
        try handle.truncate(atOffset: 0)
    }

    static func writeDurably(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError(url) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError(url) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = write(descriptor, base.advanced(by: written), buffer.count - written)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw posixError(url) }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError(url) }
    }

    static func preservingURL(for url: URL) -> URL { url.appendingPathExtension("preserving") }
    static func rotatedURL(for url: URL, generation: Int) -> URL { url.appendingPathExtension("\(generation)") }

    private func shiftGenerations(for url: URL) throws {
        let oldest = Self.rotatedURL(for: url, generation: generations)
        if try ManagedFileSystem.fileSize(at: oldest) != nil { try FileManager.default.removeItem(at: oldest) }
        guard generations > 1 else { return }
        for generation in stride(from: generations - 1, through: 1, by: -1) {
            let source = Self.rotatedURL(for: url, generation: generation)
            guard try ManagedFileSystem.fileSize(at: source) != nil else { continue }
            try FileManager.default.moveItem(at: source, to: Self.rotatedURL(for: url, generation: generation + 1))
        }
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    private func posixError(_ url: URL) -> NSError { Self.posixError(url) }
}
