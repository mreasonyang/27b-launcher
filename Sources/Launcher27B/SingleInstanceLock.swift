import Darwin
import Foundation

/// Cross-process guard that keeps a second copy of the launcher from adopting
/// or stopping the server owned by the first one.
///
/// `flock(2)` on a file inside the launcher support directory was chosen over
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` because:
///
/// * it is path based, so two copies of the app in different folders (and
///   `open -n`, which launches a second instance of the same bundle) contend for
///   the same lock file — a stale copy preserved as a backup;
/// * the kernel releases the lock automatically when the process dies, so a
///   crash never leaves a stale lock behind;
/// * it needs no LaunchServices registration, so it also works for unsigned or
///   relocated builds.
final class SingleInstanceLock: @unchecked Sendable {
    enum Acquisition: Sendable, Equatable {
        case acquired
        /// Another live process holds the lock; `ownerPID` is its process id
        /// when the owner wrote one (0 when unknown).
        case alreadyRunning(ownerPID: pid_t)
    }

    static let fileName = "launcher.lock"

    private let url: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    static func defaultURL(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    deinit {
        release()
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// True when the file at the lock path is still the inode this lock holds.
    ///
    /// `flock` protects an *inode*, not a path: if the lock file is deleted
    /// while it is held (a cleanup utility, or a user tidying the support
    /// directory) a new instance creates a fresh inode, takes its own lock and
    /// becomes primary while this process still believes it is the only one.
    /// Detecting the replacement is what lets the guarantee be repaired instead
    /// of silently voiding.
    var pathStillRefersToHeldFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return false }

        var held = Darwin.stat()
        guard fstat(descriptor, &held) == 0 else { return false }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let pathInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let pathDevice = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        else {
            return false
        }

        return pathInode == UInt64(held.st_ino) && pathDevice == UInt64(held.st_dev)
    }

    /// Attempts to take the lock without blocking. Re-entrant for the same
    /// process: calling it twice returns `.acquired` both times.
    func acquire() throws -> Acquisition {
        lock.lock()
        defer { lock.unlock() }

        if descriptor >= 0 {
            return .acquired
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SingleInstanceLockError.lockFileUnavailable(url)
        }

        // 0600: the recorded pid is not sensitive, but the file lives next to
        // other per-user launcher state and should not be world readable.
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw SingleInstanceLockError.lockFileUnavailable(url)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK else { close(fd); throw SingleInstanceLockError.lockFileUnavailable(url) }
            let owner = Self.recordedOwnerPID(at: url)
            close(fd)
            return .alreadyRunning(ownerPID: owner)
        }

        descriptor = fd
        Self.recordOwnerPID(getpid(), descriptor: fd)
        return .acquired
    }

    /// Drops the lock. Safe to call when the lock is not held.
    func release() {
        lock.lock()
        defer { lock.unlock() }

        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func recordOwnerPID(_ pid: pid_t, descriptor: Int32) {
        let payload = Array("\(pid)\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(descriptor, base, buffer.count)
        }
    }

    private static func recordedOwnerPID(at url: URL) -> pid_t {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0 else { return 0 }
        return pid
    }
}

enum SingleInstanceLockError: LocalizedError, AppLocalizableError {
    case lockFileUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case let .lockFileUnavailable(url):
            "无法创建启动器锁文件：\(url.path)"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case let .lockFileUnavailable(url):
            preferences.localizedFormat("无法创建启动器锁文件：%@", url.path)
        }
    }
}
