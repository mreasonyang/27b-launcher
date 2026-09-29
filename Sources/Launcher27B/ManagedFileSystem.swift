import Darwin
import Foundation

/// File operations distinguish absence from unreadable or invalid state.
/// No metadata error may become a guessed size or permission to continue.
enum ManagedFileSystem {
    static func metadata(at url: URL) throws -> stat? {
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        let code = errno
        if code == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    static func fileSize(at url: URL) throws -> Int64? {
        guard let value = try metadata(at: url) else { return nil }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return value.st_size
    }

    static func requiredFileSize(at url: URL) throws -> Int64 {
        guard let size = try fileSize(at: url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return size
    }

    static func removeIfPresent(_ url: URL) throws {
        if try metadata(at: url) != nil { try FileManager.default.removeItem(at: url) }
    }

    static func allocatedBytes(at url: URL) throws -> Int64 {
        guard let value = try metadata(at: url) else { return 0 }
        switch value.st_mode & S_IFMT {
        case S_IFREG:
            guard value.st_blocks >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            return value.st_blocks * 512
        case S_IFDIR:
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .reduce(Int64(0)) { try $0 + allocatedBytes(at: $1) }
        default:
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
