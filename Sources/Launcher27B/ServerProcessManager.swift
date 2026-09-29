import Darwin
import Foundation

/// A `llama-server` process found on this Mac by executable path.
struct ServerProcessDescriptor: Sendable, Equatable {
    let pid: pid_t
    let executablePath: String
    /// True when the launcher's stored PID record points at this process.
    let isManaged: Bool
    let birthIdentity: String?

    init(pid: pid_t, executablePath: String, isManaged: Bool, birthIdentity: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.isManaged = isManaged
        self.birthIdentity = birthIdentity ?? ServerProcessDiscovery.birthIdentity(of: pid)
    }
}

/// Executable-path based process lookup.
///
/// The launcher recognises its server through `proc_pidpath` equality rather
/// than through the PID alone, so a reused PID can never make it signal an
/// unrelated process.
enum ServerProcessDiscovery {
    /// `PROC_ALL_PIDS` from `<libproc.h>`.
    private static let allPIDs: UInt32 = 1

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }

        let pathBytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    /// Only the configured runtime executable is owned by this launcher.
    static func matches(
        executablePath path: String,
        expectedExecutable: URL,
        supportDirectory: URL
    ) -> Bool {
        // Resolve only the configured executable through the filesystem. The
        // candidate must equal that exact kernel path, with no basename matching.
        if let resolved = realpath(expectedExecutable.path, nil) {
            defer { free(resolved) }
            return path == String(cString: resolved)
        }
        return false
    }

    static func birthIdentity(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    /// All live PIDs whose executable is the launcher's runtime binary.
    static func runningPIDs(
        matching expectedExecutable: URL,
        supportDirectory: URL
    ) -> [pid_t] {
        let probe = proc_listpids(allPIDs, 0, nil, 0)
        guard probe > 0 else { return [] }

        let capacity = Int(probe) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listpids(
                allPIDs,
                0,
                base,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard written > 0 else { return [] }

        let count = min(Int(written) / MemoryLayout<pid_t>.size, pids.count)
        let current = getpid()

        return pids[..<count].filter { pid in
            guard pid > 0, pid != current else { return false }
            guard let path = executablePath(of: pid) else { return false }
            return matches(
                executablePath: path,
                expectedExecutable: expectedExecutable,
                supportDirectory: supportDirectory
            )
        }
    }
}

/// Finds the process that currently listens on a TCP port, whatever binary it
/// is.
///
/// The launcher recognises its own server by executable path, so a healthy port
/// owned by anything else (started by hand from another folder, or by a
/// different tool) can be explained in the UI and stopped from the launcher.
/// libproc exposes the socket list only through a C union
/// that has no stable Swift binding, so the lookup shells out to `lsof` instead
/// — a read-only, best-effort query that fails closed (returns `nil`).
enum ServerPortListenerFinder {
    /// Path of the system tool used for the lookup.
    static let lsofURL = URL(filePath: "/usr/sbin/lsof")
    /// `lsof` walks every process; this bounds the wait on a pathological system.
    static let timeout: Duration = .seconds(3)

    static func descriptor(onPort port: Int) async -> ServerProcessDescriptor? {
        guard port > 0, port <= 65_535,
              FileManager.default.isExecutableFile(atPath: lsofURL.path),
              let pid = await listeningPID(onPort: port),
              let executable = ServerProcessDiscovery.executablePath(of: pid),
              let birth = ServerProcessDiscovery.birthIdentity(of: pid)
        else {
            return nil
        }

        return ServerProcessDescriptor(
            pid: pid,
            executablePath: executable,
            isManaged: false, birthIdentity: birth
        )
    }

    /// Runs `lsof -t` and returns its answer, or `nil` once ``timeout`` elapses.
    private static func listeningPID(onPort port: Int) async -> pid_t? {
        let data = await output(
            of: lsofURL,
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            timeout: timeout
        )
        return pid(from: data)
    }

    /// Runs `executable` and returns its standard output, or `nil` once
    /// `timeout` elapses.
    ///
    /// The deadline *returns* instead of waiting for the child. The previous
    /// `withTaskGroup` race did not bound anything: a task group implicitly
    /// awaits every child at scope exit, so a cancelled-but-blocked child still
    /// held the caller for its whole lifetime (a standalone reproduction with a
    /// 0.5 s "timeout" took 5.33 s). This call sits inside `refresh()`, so one
    /// stalled `lsof` froze the monitoring tick — including auto-restart. Here a
    /// resume-once continuation is resolved by whichever comes first, the child
    /// exiting or the deadline, and the still-running child is retained in
    /// ``PendingPortProbes`` so it is reaped when it finally exits instead of
    /// becoming a zombie.
    ///
    /// The deadline timer is registered before the child is launched and is torn
    /// down by ``DeadlineRace/resolve(_:outcome:report:)`` the instant the race is
    /// decided. A probe whose child answers immediately therefore costs no
    /// lingering sleeping task, instead of one parked for the whole timeout.
    ///
    /// Internal so the bounding can be asserted directly with a deliberately
    /// slow child, and so ``report`` can prove the teardown.
    static func output(
        of executable: URL,
        arguments: [String],
        timeout: Duration,
        report: PortProbeDeadlineReport? = nil
    ) async -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let race = DeadlineRace()
        process.terminationHandler = { finished in
            let data = try? output.fileHandleForReading.readToEnd()
            try? output.fileHandleForReading.close()
            PendingPortProbes.shared.reap(finished)
            race.resolve(data, outcome: .childExited, report: report)
        }

        // Registered *before* `run()` so the race always owns the timer: a child
        // that exits immediately cannot beat `attach` and leak it.
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // Cancelled because the child decided the race first.
                return
            }
            race.resolve(nil, outcome: .deadlineElapsed, report: report)
        }
        race.attach(deadline: deadline)

        do {
            try process.run()
        } catch {
            deadline.cancel()
            return nil
        }
        PendingPortProbes.shared.retain(process)
        return await race.wait()
    }

    /// Which side of a port probe's deadline race decided the outcome.
    enum PortProbeRaceOutcome: Sendable, Equatable {
        case childExited
        case deadlineElapsed
    }

    /// Per-call instrumentation for ``output(of:arguments:timeout:report:)``.
    ///
    /// Internal and per call (rather than a process-wide counter) so a test can
    /// prove that a fast child leaves no deadline timer parked, without sharing
    /// mutable state with other tests.
    final class PortProbeDeadlineReport: @unchecked Sendable {
        private let lock = NSLock()
        private var _outcome: PortProbeRaceOutcome?
        private var _cancelledTimers = 0

        /// The side that won the race, or `nil` if the probe never decided.
        var outcome: PortProbeRaceOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return _outcome
        }

        /// How many deadline timers were cancelled because the child exited
        /// first, i.e. the sleeping tasks that did *not* wait out the timeout.
        var cancelledTimers: Int {
            lock.lock()
            defer { lock.unlock() }
            return _cancelledTimers
        }

        func record(outcome: PortProbeRaceOutcome) {
            lock.lock()
            _outcome = outcome
            lock.unlock()
        }

        func recordCancelledTimer() {
            lock.lock()
            _cancelledTimers += 1
            lock.unlock()
        }
    }

    private static func pid(from data: Data?) -> pid_t? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let candidates = Set(text.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 })
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    /// Resumes exactly once: the first of "the child exited" and "the deadline
    /// elapsed" wins and the loser becomes a no-op.
    private final class DeadlineRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var resolved: Data?
        private var hasResolved = false
        private var deadline: Task<Void, Never>?

        /// Hands the deadline timer to the race, so the winning side can cancel
        /// it. Called before the child is launched; a race that somehow already
        /// decided cancels the timer immediately.
        func attach(deadline: Task<Void, Never>) {
            lock.lock()
            let alreadyResolved = hasResolved
            if alreadyResolved {
                lock.unlock()
                deadline.cancel()
                return
            }
            self.deadline = deadline
            lock.unlock()
        }

        func resolve(
            _ value: Data?,
            outcome: PortProbeRaceOutcome,
            report: PortProbeDeadlineReport?
        ) {
            lock.lock()
            guard !hasResolved else {
                lock.unlock()
                return
            }
            hasResolved = true
            resolved = value
            let deadline = self.deadline
            self.deadline = nil
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            // Tear the losing side down at once. Without this a probe whose child
            // exited in milliseconds still paid for a task sleeping the full
            // timeout (3 s per `lsof` lookup in production).
            if outcome == .childExited, let deadline {
                deadline.cancel()
                report?.recordCancelledTimer()
            }
            report?.record(outcome: outcome)
            continuation?.resume(returning: value)
        }

        func wait() async -> Data? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasResolved {
                    let value = resolved
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    /// Holds probes that outlived their deadline until they exit, so the OS can
    /// reap them. The lookup is cached by ``ServerProcessManager``, so this stays
    /// small even on a machine where `lsof` repeatedly stalls.
    final class PendingPortProbes: @unchecked Sendable {
        static let shared = PendingPortProbes()

        /// A stalled `lsof` is rare and the lookup is cached, but a permanently
        /// hung child must not accumulate without bound.
        static let defaultMaximumRetained = 8

        private let maximumRetained: Int
        private let lock = NSLock()
        private var processes: [Process] = []
        /// Probes evicted from ``processes`` while *still running*.
        ///
        /// Dropping the last strong reference to a live child is what left it
        /// unreaped, so these are kept referenced and signalled instead. Their
        /// termination handler calls ``reap(_:)``, which is what releases them
        /// again — so the list cannot grow without bound while the kill works.
        private var evictedLiveChildren: [Process] = []

        init(maximumRetained: Int = PendingPortProbes.defaultMaximumRetained) {
            self.maximumRetained = maximumRetained
        }

        /// How many evicted-but-live children are still being retained so they
        /// can be reaped. Internal for the eviction test.
        var evictedLiveChildCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return evictedLiveChildren.count
        }

        func retain(_ process: Process) {
            lock.lock()
            processes.append(process)
            var overflow: [Process] = []
            if processes.count > maximumRetained {
                let count = processes.count - maximumRetained
                overflow = Array(processes.prefix(count))
                processes.removeFirst(count)
                evictedLiveChildren.append(contentsOf: overflow.filter(\.isRunning))
            }
            lock.unlock()

            // Signal the evicted children that are still alive. They already blew
            // their deadline, so SIGKILL is the only way to guarantee they exit
            // and can be reaped rather than accumulating.
            for child in overflow where child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
            }
        }

        func reap(_ process: Process) {
            lock.lock()
            processes.removeAll { $0 === process }
            evictedLiveChildren.removeAll { $0 === process }
            lock.unlock()
        }
    }
}

/// `UserDefaults` is thread safe but not `Sendable`. Only the server PID record
/// is ever read or written, so the reference is boxed instead of being copied
/// into the actor's isolation domain.
struct ServerDefaults: @unchecked Sendable {
    static let standard = ServerDefaults(.standard)

    let storage: UserDefaults

    init(_ storage: UserDefaults) {
        self.storage = storage
    }
}

actor ServerProcessManager {
    /// How often the live logs are checked against the rotation cap. The
    /// open-time check alone left one long session unbounded.
    private static let logCapCheckInterval: Duration = .seconds(1)

    /// How long a port-listener lookup is reused before `lsof` runs again.
    ///
    /// A foreign listener that owns the port is otherwise re-probed on every
    /// monitoring cycle (roughly every 2 s) for as long as it exists; caching
    /// bounds that to one spawn per window without making the card stale for
    /// long. The identity re-check before a signal always probes afresh.
    private static let listenerCacheLifetime: Duration = .seconds(10)

    private let config: LauncherConfig
    private let argumentsBuilder: ServerArgumentsBuilder
    private let defaults: ServerDefaults
    private let apiKeyStore: ApiKeyStore
    private let logRotation: ServerLogRotation
    /// How long a stopped server is given to exit on `SIGTERM` before `SIGKILL`.
    private let terminationGracePeriod: Duration
    /// How long the forced `SIGKILL` is given before the stop is declared failed.
    private let terminationForceTimeout: Duration
    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var logCapTask: Task<Void, Never>?
    private var cachedPortListener: (descriptor: ServerProcessDescriptor?, checkedAt: ContinuousClock.Instant)?

    private let pidKey = "bonsaiServerPID"
    private let launchRecordKey = "serverLaunchRecord"
    private let processIdentityKey = "serverProcessIdentity"

    func runningLaunchOptions() -> ServerLaunchOptions? {
        guard isRunning(), let pid = managedPID(),
              let identity = ServerProcessDiscovery.birthIdentity(of: pid),
              let record = defaults.storage.dictionary(forKey: launchRecordKey),
              record["identity"] as? String == identity,
              record["executable"] as? String == config.serverBinary.path,
              let bind = record["bindMode"] as? String, let mode = ServerBindMode(rawValue: bind),
              let strength = record["strength"] as? String, let value = AblationStrength(rawValue: strength),
              let enabled = record["ablation"] as? Bool else { return nil }
        return ServerLaunchOptions(ablationEnabled: enabled, ablationStrength: value, bindMode: mode)
    }


    init(
        config: LauncherConfig,
        argumentsBuilder: ServerArgumentsBuilder = ServerArgumentsBuilder(),
        defaults: ServerDefaults = .standard,
        apiKeyStore: ApiKeyStore? = nil,
        logRotation: ServerLogRotation = ServerLogRotation(),
        terminationGracePeriod: Duration = .seconds(20),
        terminationForceTimeout: Duration = .seconds(5)
    ) {
        self.config = config
        self.argumentsBuilder = argumentsBuilder
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
            ?? ApiKeyStore.applicationDefault(supportDirectory: config.supportDirectory)
        self.logRotation = logRotation
        self.terminationGracePeriod = terminationGracePeriod
        self.terminationForceTimeout = terminationForceTimeout
    }

    // MARK: - State

    func isRunning() -> Bool {
        guard let pid = managedPID() else { return false }
        let running = managedProcessIsRunning(pid: pid)
        if !running {
            clearProcessState()
        }
        return running
    }

    /// The running server found by executable path, whether or not the launcher
    /// still has a PID record for it.
    func discoverRunningServer() -> ServerProcessDescriptor? {
        let managed = managedPID()
        let candidates = ServerProcessDiscovery.runningPIDs(
            matching: config.serverBinary,
            supportDirectory: config.supportDirectory
        )
        guard !candidates.isEmpty else { return nil }

        let pid: pid_t
        if let managed, candidates.contains(managed) { pid = managed }
        else if candidates.count == 1 { pid = candidates[0] }
        else { return nil }
        guard let executable = ServerProcessDiscovery.executablePath(of: pid),
              let birth = ServerProcessDiscovery.birthIdentity(of: pid) else { return nil }
        return ServerProcessDescriptor(
            pid: pid,
            executablePath: executable,
            isManaged: pid == managed, birthIdentity: birth
        )
    }

    /// Re-attaches the launcher to a server it no longer has a PID record for
    /// (preferences reset, migrated install, reclaimed plist, reinstalled
    /// runtime). Returns the adopted process, or `nil` when none was found.
    @discardableResult
    func adoptDiscoveredServer() -> ServerProcessDescriptor? {
        guard let descriptor = discoverRunningServer() else { return nil }
        defaults.storage.removeObject(forKey: launchRecordKey)
        defaults.storage.set(ServerProcessDiscovery.birthIdentity(of: descriptor.pid), forKey: processIdentityKey)
        defaults.storage.set(Int(descriptor.pid), forKey: pidKey)
        return ServerProcessDescriptor(
            pid: descriptor.pid,
            executablePath: descriptor.executablePath,
            isManaged: true
        )
    }

    // MARK: - Lifecycle

    func start(options: ServerLaunchOptions) throws {
        guard !isRunning(), discoverRunningServer() == nil else {
            throw ServerProcessError.portStillResponding
        }

        if options.ablationEnabled,
           !FileManager.default.fileExists(atPath: config.ablationAdapterFile.path) {
            throw ServerProcessError.adapterMissing(config.ablationAdapterFile)
        }
        guard FileManager.default.fileExists(atPath: config.webUIConfigFile.path) else {
            throw ServerProcessError.webUIConfigMissing(config.webUIConfigFile)
        }

        // The key is only handed to the server when the launcher exposes it to
        // the local network; loopback keeps today's argument set and does not
        // create a key file for users who never leave this Mac.
        let apiKey = options.bindMode == .allInterfaces
            ? try apiKeyStore.loadOrCreateKey()
            : nil

        let stdout = try logRotation.openLog(
            at: config.standardOutputURL,
            header: sessionHeader(
                stream: "stdout",
                detail: "llama-server 将所有日志写入 stderr；本文件通常为空，实际日志见 server.error.log。",
                apiKey: apiKey,
                options: options
            )
        )

        let stderr: FileHandle
        do {
            stderr = try logRotation.openLog(
                at: config.standardErrorURL,
                header: sessionHeader(
                    stream: "stderr",
                    detail: "已通过 -lv \(ServerArgumentsBuilder.logVerbosity) 抑制常规 INFO 日志。",
                    apiKey: apiKey,
                    options: options
                )
            )
        } catch {
            try? stdout.close()
            throw error
        }

        let task = Process()
        task.executableURL = config.serverBinary
        task.arguments = argumentsBuilder.makeArguments(
            config: config,
            options: options
        )
        task.currentDirectoryURL = config.serverBinary.deletingLastPathComponent()

        // Only a minimal allowlist reaches the downloaded third-party binary.
        // The full user environment can carry tokens, proxy credentials and
        // LLAMA_ARG_* overrides that would silently change server behaviour.
        task.environment = Self.childEnvironment(from: ProcessInfo.processInfo.environment)
        let credentialPipe = apiKey == nil ? nil : Pipe()
        if let credentialPipe { task.standardInput = credentialPipe }
        else { task.standardInput = FileHandle.nullDevice }
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw error
        }

        if let credentialPipe, let apiKey {
            do {
                try credentialPipe.fileHandleForWriting.write(contentsOf: Data((apiKey + "\n").utf8))
                try credentialPipe.fileHandleForWriting.close()
            } catch {
                task.terminate()
                try? stdout.close()
                try? stderr.close()
                throw error
            }
        }
        process = task
        outputHandle = stdout
        errorHandle = stderr
        defaults.storage.set(ServerProcessDiscovery.birthIdentity(of: task.processIdentifier), forKey: processIdentityKey)
        defaults.storage.set(Int(task.processIdentifier), forKey: pidKey)
        if let identity = ServerProcessDiscovery.birthIdentity(of: task.processIdentifier) {
            defaults.storage.set([
                "identity": identity, "executable": config.serverBinary.path,
                "bindMode": options.bindMode.rawValue,
                "strength": options.ablationStrength.rawValue, "ablation": options.ablationEnabled
            ], forKey: launchRecordKey)
        }

        startLogCapEnforcement()
    }

    func stop() async throws {
        // The teardown runs even when the stop throws: a failed termination used
        // to leave the log-cap task and both log handles alive, because the
        // cleanup was only reached on the success path.
        guard let pid = managedPID(), managedProcessIsRunning(pid: pid) else {
            clearProcessState()
            return
        }
        try await terminate(pid: pid, expectedBirth: defaults.storage.string(forKey: processIdentityKey))
        clearProcessState()
    }

    /// Stops a server the launcher no longer has a PID record for. Owns the
    /// escalated shutdown so a later UI phase can offer "stop the orphan" with
    /// the same guarantees as ``stop()``.
    func stopDiscoveredServer() async throws {
        guard let descriptor = discoverRunningServer() else {
            return
        }
        try await terminate(pid: descriptor.pid, expectedBirth: descriptor.birthIdentity)
    }

    // MARK: - Foreign port owner

    /// The process currently listening on the launcher's port, whatever binary
    /// it is, so the UI can explain (and offer to release) a healthy port the
    /// launcher cannot adopt.
    ///
    /// Cached for ``listenerCacheLifetime``: `refresh()` probes this on every
    /// monitoring cycle while a foreign listener holds the port, and spawning
    /// `lsof` every two seconds forever is pure waste. Use ``probePortListener()``
    /// when a fresh answer is required.
    func portListener() async -> ServerProcessDescriptor? {
        if let cachedPortListener,
           ContinuousClock().now < cachedPortListener.checkedAt.advanced(
               by: Self.listenerCacheLifetime
           ) {
            return cachedPortListener.descriptor
        }
        return await probePortListener()
    }

    /// Stops the process occupying the launcher's port when it is *not* the
    /// launcher's own runtime binary.
    ///
    /// `expected` is the descriptor the user was shown and confirmed; the
    /// listener is re-identified immediately before the first signal, so a PID
    /// that was reused since the card was rendered is never signalled.
    func stopPortListener(_ expected: ServerProcessDescriptor) async throws {
        try await terminate(pid: expected.pid) {
            await self.portIdentity(of: expected)
        }
    }

    /// How the listener on the launcher's port compares to what the user
    /// confirmed. Always probes afresh: a cached answer could name a PID that
    /// has since been reused.
    ///
    /// Internal so the port-specific identity check can be asserted directly.
    func portIdentity(of expected: ServerProcessDescriptor) async -> TargetIdentity {
        guard let current = await probePortListener() else { return .gone }
        guard current.pid == expected.pid,
              current.executablePath == expected.executablePath,
              let birth = expected.birthIdentity, current.birthIdentity == birth
        else {
            return .unrelated
        }
        return .identified
    }

    /// A lookup that always spawns `lsof`, refreshing the cache.
    private func probePortListener() async -> ServerProcessDescriptor? {
        guard let port = config.chatURL.port else { return nil }
        let descriptor = await ServerPortListenerFinder.descriptor(onPort: port)
        cachedPortListener = (descriptor, ContinuousClock().now)
        return descriptor
    }

    // MARK: - Log cap enforcement

    /// Trims the live stdout/stderr files once they pass the rotation cap, so a
    /// single long session cannot grow without bound.
    ///
    /// Internal so one enforcement pass can be driven without the timer.
    private var logFailure: String?

    func logMaintenanceFailure() -> String? { logFailure }

    func enforceLogCaps() throws {
        if let outputHandle {
            try logRotation.enforceCap(at: config.standardOutputURL, handle: outputHandle)
        }
        if let errorHandle {
            try logRotation.enforceCap(at: config.standardErrorURL, handle: errorHandle)
        }
    }

    private func recordLogFailure(_ error: Error) { logFailure = error.localizedDescription }

    private func startLogCapEnforcement() {
        logCapTask?.cancel()
        logFailure = nil
        logCapTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.logCapCheckInterval)
                guard !Task.isCancelled, let self else { return }
                do { try await self.enforceLogCaps() }
                catch {
                    await self.recordLogFailure(error)
                    return
                }
            }
        }
    }

    // MARK: - Environment

    /// Keys that are safe to hand to the server process.
    static let inheritedEnvironmentKeys = ["PATH", "HOME", "TMPDIR", "LANG"]
    private static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Minimal environment for the child process: the basics llama.cpp needs to
    /// run and find its caches, plus `LC_*` locale hints. Everything else —
    /// cloud tokens, proxy credentials, `LLAMA_ARG_*` overrides — is dropped.
    static func childEnvironment(from source: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in inheritedEnvironmentKeys {
            guard let value = source[key], !value.isEmpty else { continue }
            environment[key] = value
        }

        for (key, value) in source where key.hasPrefix("LC_") {
            environment[key] = value
        }

        if environment["PATH"] == nil {
            environment["PATH"] = defaultPath
        }
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }

        return environment
    }

    // MARK: - Process helpers

    private func managedPID() -> pid_t? {
        let stored = defaults.storage.integer(forKey: pidKey)
        guard stored > 0, stored <= Int(Int32.max),
              let identity = defaults.storage.string(forKey: processIdentityKey),
              identity == ServerProcessDiscovery.birthIdentity(of: pid_t(stored)) else { return nil }
        return pid_t(stored)
    }

    private func expectedExecutableIsRunning(pid: pid_t) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return false }

        guard let path = ServerProcessDiscovery.executablePath(of: pid) else { return false }

        return ServerProcessDiscovery.matches(
            executablePath: path,
            expectedExecutable: config.serverBinary,
            supportDirectory: config.supportDirectory
        )
    }

    private func managedProcessIsRunning(pid: pid_t) -> Bool {
        if let process, process.processIdentifier == pid {
            return process.isRunning
        }
        return expectedExecutableIsRunning(pid: pid)
    }

    private func processIsAlive(pid: pid_t) -> Bool {
        if let process, process.processIdentifier == pid {
            return process.isRunning
        }
        return Darwin.kill(pid, 0) == 0
    }

    /// Stops one of the launcher's own server processes.
    ///
    /// Internal so the identity re-verification that happens immediately before
    /// each signal can be asserted directly.
    func terminate(pid: pid_t) async throws {
        try await terminate(pid: pid, expectedBirth: ServerProcessDiscovery.birthIdentity(of: pid))
    }

    private func terminate(pid: pid_t, expectedBirth: String?) async throws {
        try await terminate(pid: pid) {
            Self.identity(of: pid, config: self.config, expectedBirth: expectedBirth)
        }
    }
    /// How a target PID relates to what the launcher believes it identified.
    enum TargetIdentity: Equatable {
        /// The PID still runs the process the launcher identified.
        case identified
        /// No process at that PID any more.
        case gone
        /// A live process, but not the one the launcher identified.
        case unrelated
    }

    nonisolated static func identity(
        of pid: pid_t,
        config: LauncherConfig,
        expectedBirth: String?
    ) -> TargetIdentity {
        guard Darwin.kill(pid, 0) == 0 else {
            return errno == ESRCH ? .gone : .unrelated
        }
        guard let expectedBirth, expectedBirth == ServerProcessDiscovery.birthIdentity(of: pid),
              let path = ServerProcessDiscovery.executablePath(of: pid) else { return .unrelated }
        return ServerProcessDiscovery.matches(
            executablePath: path,
            expectedExecutable: config.serverBinary,
            supportDirectory: config.supportDirectory
        ) ? .identified : .unrelated
    }

    /// SIGTERM → wait → SIGKILL → wait.
    ///
    /// `identity` is re-evaluated immediately before *each* signal. A PID that
    /// stops being the process the launcher identified (reused during the 20 s
    /// wait, or matched too loosely at discovery time) is refused. An unrelated
    /// target maps onto the existing "could not stop the model process" error,
    /// and no signal is sent.
    ///
    /// Internal, with an injectable identity closure, so both re-checks can be
    /// asserted — including the one that guards the `SIGKILL`.
    func terminate(
        pid: pid_t,
        identity: () async -> TargetIdentity
    ) async throws {
        switch await identity() {
        case .gone:
            // Already exited; there is nothing to signal.
            return
        case .unrelated:
            throw ServerProcessError.signalFailed(errno: ESRCH)
        case .identified:
            break
        }

        guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw ServerProcessError.signalFailed(errno: errno)
        }

        if await waitForExit(
            pid: pid,
            timeout: terminationGracePeriod,
            interval: .milliseconds(250)
        ) {
            return
        }

        switch await identity() {
        case .gone:
            return
        case .unrelated:
            throw ServerProcessError.signalFailed(errno: ESRCH)
        case .identified:
            break
        }

        guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else {
            throw ServerProcessError.signalFailed(errno: errno)
        }

        if await waitForExit(
            pid: pid,
            timeout: terminationForceTimeout,
            interval: .milliseconds(100)
        ) {
            return
        }

        throw ServerProcessError.forceStopTimedOut
    }

    private func waitForExit(
        pid: pid_t,
        timeout: Duration,
        interval: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if !processIsAlive(pid: pid) { return true }
            try? await Task.sleep(for: interval)
        }

        return !processIsAlive(pid: pid)
    }

    private func sessionHeader(
        stream: String,
        detail: String,
        apiKey: String?,
        options: ServerLaunchOptions
    ) -> String {
        let timestamp = Date.now.formatted(.iso8601)
        let webUI = options.bindMode == .allInterfaces ? "已禁用（--no-webui）" : "已启用"
        let keyState = apiKey == nil ? "未设置（仅本机模式）" : "已设置（值不写入日志）"

        return """
        ===== 27B Launcher 会话开始 (\(stream)) =====
        时间: \(timestamp)
        运行程序: \(config.serverBinary.path)
        模型: \(config.modelFile.path)
        监听: \(options.bindMode.hostArgument):8080
        Web UI: \(webUI)
        API 密钥: \(keyState)
        \(detail)

        """
    }

    private func clearProcessState() {
        logCapTask?.cancel()
        logCapTask = nil
        defaults.storage.removeObject(forKey: pidKey)
        defaults.storage.removeObject(forKey: processIdentityKey)
        defaults.storage.removeObject(forKey: launchRecordKey)
        process = nil
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        cachedPortListener = nil
    }
}

enum ServerProcessError: LocalizedError, AppLocalizableError, Equatable {
    case signalFailed(errno: Int32)
    case forceStopTimedOut
    case healthCheckTimedOut
    case exitedBeforeReady
    case portStillResponding
    case logCreationFailed(URL)
    case adapterMissing(URL)
    case webUIConfigMissing(URL)

    var errorDescription: String? {
        switch self {
        case let .signalFailed(code):
            "无法停止模型进程（errno \(code)）"
        case .forceStopTimedOut:
            "模型进程未能在强制停止后退出"
        case .healthCheckTimedOut:
            "模型进程已启动，但未能通过健康检查；已停止进程，请查看日志"
        case .exitedBeforeReady:
            "模型进程在加载完成前退出，请查看日志或在设置中校验文件。"
        case .portStillResponding:
            "停止模型后端口仍有服务响应；为避免端口冲突，未执行重启"
        case let .logCreationFailed(url):
            "无法创建日志文件：\(url.path)"
        case let .adapterMissing(url):
            "OrcaBonsai 适配器不存在：\(url.path)。请重新安装缺失组件。"
        case let .webUIConfigMissing(url):
            "WebUI 配置文件不存在：\(url.path)。请重新安装 27B Launcher。"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case let .signalFailed(code):
            preferences.localizedFormat("无法停止模型进程（errno %lld）", Int64(code))
        case .forceStopTimedOut:
            preferences.localized("模型进程未能在强制停止后退出")
        case .healthCheckTimedOut:
            preferences.localized("模型进程已启动，但未能通过健康检查；已停止进程，请查看日志")
        case .exitedBeforeReady:
            preferences.localized("模型进程在加载完成前退出，请查看日志或在设置中校验文件。")
        case .portStillResponding:
            preferences.localized("停止模型后端口仍有服务响应；为避免端口冲突，未执行重启")
        case let .logCreationFailed(url):
            preferences.localizedFormat("无法创建日志文件：%@", url.path)
        case let .adapterMissing(url):
            preferences.localizedFormat(
                "OrcaBonsai 适配器不存在：%@。请重新安装缺失组件。",
                url.path
            )
        case let .webUIConfigMissing(url):
            preferences.localizedFormat(
                "WebUI 配置文件不存在：%@。请重新安装 27B Launcher。",
                url.path
            )
        }
    }
}
