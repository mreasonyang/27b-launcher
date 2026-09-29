import CryptoKit
import Foundation

struct FileChecksum: Sendable {
    private static let chunkSize = 1_048_576

    /// Streams the file through SHA-256, observing task cancellation between chunks so
    /// a multi-gigabyte hash cannot block a pause/cancel request for minutes.
    func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().reduce(into: "") { result, byte in
            if byte < 16 {
                result.append("0")
            }
            result.append(String(byte, radix: 16))
        }
    }
}
