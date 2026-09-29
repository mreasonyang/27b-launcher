import Darwin
import Foundation

enum DiskCapacity {
    static func available(at url: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow, bytes <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        return Int64(bytes)
    }
}
