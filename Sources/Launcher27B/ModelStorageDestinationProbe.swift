import Foundation

/// Capabilities of the volume that is about to receive a model migration.
///
/// The values are queried once, before the first byte is written, so an
/// unsupported destination is rejected up front instead of failing after a
/// multi-gigabyte copy (for example a FAT32 stick that cannot hold a file
/// larger than 4 GB).
struct ModelStorageDestinationDescriptor: Sendable, Equatable {
    let fileSystemName: String
    let isLocal: Bool
    let isReadOnly: Bool
    let supportsFilesAbove4GB: Bool
    let availableBytes: Int64?

    /// File systems that are known to cap a single file at 4 GB. macOS reports a
    /// FAT32 volume as `msdos`, so this name check is the reliable signal.
    static let restrictedFileSystemNames: Set<String> = ["msdos", "fat", "vfat"]

    /// File systems known to accept files above 4 GB. A name outside both this set
    /// and ``restrictedFileSystemNames`` is unknown and deliberately *not* treated
    /// as capable: the size probe cannot prove a filesystem is safe, only that it
    /// is unsafe.
    static let capableFileSystemNames: Set<String> = [
        "apfs", "hfs", "exfat", "ntfs", "ufs", "zfs",
        "ext2", "ext3", "ext4", "xfs", "btrfs",
    ]

    var isKnownSizeRestrictedFileSystem: Bool {
        Self.restrictedFileSystemNames.contains(fileSystemName.lowercased())
    }
}

/// Queries the volume backing a destination directory.
enum ModelStorageDestinationProbe {
    /// The largest single file a 4 GB-capped volume can hold.
    static let fourGigabyteLimit: Int64 = 4 * 1024 * 1024 * 1024 - 1

    static func descriptor(at url: URL) -> ModelStorageDestinationDescriptor? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeAvailableCapacityKey,
        ]) else {
            return nil
        }

        // Fail closed. A volume whose locality or write capability cannot be
        // determined is not silently treated as a writable local disk; the caller
        // refuses the migration instead.
        guard let isLocal = values.volumeIsLocal,
              let isReadOnly = values.volumeIsReadOnly else {
            return nil
        }

        let fileSystemName = fileSystemName(at: url) ?? "unknown"
        return ModelStorageDestinationDescriptor(
            fileSystemName: fileSystemName,
            isLocal: isLocal,
            isReadOnly: isReadOnly,
            supportsFilesAbove4GB: supportsFileSizesAbove4GB(
                at: url,
                fileSystemName: fileSystemName
            ),
            availableBytes: try? DiskCapacity.available(at: url)
        )
    }

    /// Whether the volume can hold a single file larger than 4 GB.
    ///
    /// The filesystem *name* is the primary signal: macOS reports a FAT32 volume as
    /// `msdos`, and that is the only check that actually works.
    /// `_PC_FILESIZEBITS` is a secondary check and is *not* a capability proof: it
    /// was measured to return 33 for FAT32 (above 32, so a `> 32` test wrongly
    /// calls a 4 GB-capped volume capable), 56 for APFS and 64 for exFAT. It is
    /// therefore only trusted when it confirms a ≤ 32-bit limit.
    ///
    /// A filesystem that is neither known-restricted nor known-capable is reported
    /// as not capable rather than defaulting to capable.
    static func supportsFileSizesAbove4GB(at url: URL, fileSystemName: String) -> Bool {
        let name = fileSystemName.lowercased()
        if ModelStorageDestinationDescriptor.restrictedFileSystemNames.contains(name) {
            return false
        }
        let filesizeBits = url.path.withCString { pathconf($0, _PC_FILESIZEBITS) }
        if filesizeBits > 0, filesizeBits <= 32 {
            return false
        }
        return ModelStorageDestinationDescriptor.capableFileSystemNames.contains(name)
    }

    /// Filesystem type name (for example `apfs`, `exfat`, `msdos`, `smbfs`).
    static func fileSystemName(at url: URL) -> String? {
        var statistics = statfs()
        guard statfs(url.path, &statistics) == 0 else { return nil }
        return withUnsafeBytes(of: &statistics.f_fstypename) { raw in
            let bytes = raw.prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
