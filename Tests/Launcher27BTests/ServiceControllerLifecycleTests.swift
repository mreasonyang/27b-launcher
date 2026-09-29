import AppKit
import Darwin
import Foundation
import Testing
@testable import Launcher27B

/// A `ServerProcessControlling` stand-in that records calls and lets a test
/// decide what `isRunning()`/`start()` do, so lifecycle supervision can be
/// exercised without launching a real `llama-server`.
final class StubServerProcessManager: ServerProcessControlling, @unchecked Sendable {
    private let lock = NSLock()

    private var _isRunning = false
    private var _discovered: ServerProcessDescriptor?
    private var _portListener: ServerProcessDescriptor?
    private var _adoptSucceeds = true
    private var _startError: Error?
    private var _stopError: Error?
    private var _stopPortListenerError: Error?
    private var _stopHook: (@Sendable () async -> Void)?
    private var _isRunningCallCount = 0

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var adoptCallCount = 0
    private(set) var stopDiscoveredCallCount = 0
    private(set) var portListenerCallCount = 0
    private(set) var stopPortListenerCallCount = 0
    private(set) var lastLaunchOptions: ServerLaunchOptions?

    var isRunningValue: Bool {
        get { withLock { _isRunning } }
        set { withLock { _isRunning = newValue } }
    }

    var isRunningCallCount: Int {
        withLock { _isRunningCallCount }
    }

    var discovered: ServerProcessDescriptor? {
        get { withLock { _discovered } }
        set { withLock { _discovered = newValue } }
    }

    /// What ``portListener()`` reports: a listener that is *not* the launcher's
    /// runtime binary.
    var portListenerValue: ServerProcessDescriptor? {
        get { withLock { _portListener } }
        set { withLock { _portListener = newValue } }
    }

    var adoptSucceeds: Bool {
        get { withLock { _adoptSucceeds } }
        set { withLock { _adoptSucceeds = newValue } }
    }

    var startError: Error? {
        get { withLock { _startError } }
        set { withLock { _startError = newValue } }
    }

    var stopError: Error? {
        get { withLock { _stopError } }
        set { withLock { _stopError = newValue } }
    }

    var stopPortListenerError: Error? {
        get { withLock { _stopPortListenerError } }
        set { withLock { _stopPortListenerError = newValue } }
    }

    /// Awaited inside ``stop()``, so a test can park a model migration at the
    /// exact moment the service has been stopped but the run intent has not yet
    /// been restored.
    var stopHook: (@Sendable () async -> Void)? {
        get { withLock { _stopHook } }
        set { withLock { _stopHook = newValue } }
    }

    func runningLaunchOptions() async -> ServerLaunchOptions? { withLock { _isRunning ? lastLaunchOptions : nil } }

    func isRunning() async -> Bool {
        withLock { () -> Bool in
            _isRunningCallCount += 1
            return _isRunning
        }
    }

    func start(options: ServerLaunchOptions) async throws {
        let error: Error? = withLock {
            startCallCount += 1
            lastLaunchOptions = options
            return _startError
        }
        if let error { throw error }
        withLock { _isRunning = true }
    }

    func stop() async throws {
        let error: Error? = withLock {
            stopCallCount += 1
            return _stopError
        }
        if let hook = withLock({ _stopHook }) { await hook() }
        if let error { throw error }
        withLock { _isRunning = false }
    }

    func discoverRunningServer() async -> ServerProcessDescriptor? {
        withLock { _discovered }
    }

    @discardableResult
    func adoptDiscoveredServer() async -> ServerProcessDescriptor? {
        withLock { () -> ServerProcessDescriptor? in
            adoptCallCount += 1
            guard _adoptSucceeds, let discovered = _discovered else { return nil }
            _isRunning = true
            lastLaunchOptions = nil
            return ServerProcessDescriptor(
                pid: discovered.pid,
                executablePath: discovered.executablePath,
                isManaged: true
            )
        }
    }

    func stopDiscoveredServer() async throws {
        withLock {
            stopDiscoveredCallCount += 1
            _isRunning = false
            _discovered = nil
        }
    }

    func portListener() async -> ServerProcessDescriptor? {
        withLock { () -> ServerProcessDescriptor? in
            portListenerCallCount += 1
            return _portListener
        }
    }

    func stopPortListener(_ expected: ServerProcessDescriptor) async throws {
        let error: Error? = withLock {
            stopPortListenerCallCount += 1
            return _stopPortListenerError
        }
        if let error { throw error }
        withLock {
            _isRunning = false
            _portListener = nil
        }
    }

    /// Waits until `isRunning()` has been called at least `expected` times.
    func waitForIsRunningCalls(_ expected: Int) async {
        while isRunningCallCount < expected {
            await Task.yield()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Health probe whose answers a test controls, including a first call that is
/// parked so two overlapping `refresh()` calls can be interleaved
/// deterministically without sleeping.
actor StubHealthProbe {
    private var value: Bool
    private var callCount = 0
    private var parksFirstCall = false
    private var parkedFirst: CheckedContinuation<Bool, Never>?

    init(value: Bool = false) {
        self.value = value
    }

    func parkFirstCall() {
        parksFirstCall = true
    }

    func probe(_ baseURL: URL) async -> Bool {
        callCount += 1
        if callCount == 1, parksFirstCall {
            return await withCheckedContinuation { continuation in
                parkedFirst = continuation
            }
        }
        return value
    }

    func resumeFirstCall(with result: Bool) {
        parkedFirst?.resume(returning: result)
        parkedFirst = nil
    }

    func setValue(_ newValue: Bool) {
        value = newValue
    }

    func waitForCallCount(_ expected: Int) async {
        while callCount < expected {
            await Task.yield()
        }
    }
}

/// Installer stand-in that stays in flight until the test cancels it, so the
/// "installation in progress" gate can be observed without transferring 8 GB.
actor InstallGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

/// Serialized because ``quittingTheLauncherLeavesTheServerRunning`` posts the
/// process-global `NSApplication.willTerminateNotification`, which would fire
/// the termination observers of any other controller test running in parallel.
@Suite(.serialized)
struct ServiceControllerLifecycleTests {
    // MARK: - Fixtures

    /// A supervision clock the test moves by hand, so the production stability
    /// window and crash-rate window can be crossed without sleeping.
    final class TestInstant: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now

        var value: ContinuousClock.Instant {
            withLock { instant }
        }

        func advance(by duration: Duration) {
            withLock { instant = instant.advanced(by: duration) }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeConfig(root: URL) -> LauncherConfig {
        LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: root.path],
            homeDirectory: root
        )
    }

    /// Same installation, but with the endpoint on a port nothing listens on.
    ///
    /// `LauncherConfig.makeLocalInstallation` points at 127.0.0.1:8080, and these
    /// supervision tests poll health once per cycle: an unreachable port keeps
    /// `/metrics` from ever reaching whatever real service happens to own 8080 on
    /// the machine running the suite.
    private func makeConfig(root: URL, unusedChatPort: Int) -> LauncherConfig {
        let base = makeConfig(root: root)
        return LauncherConfig(
            serverBinary: base.serverBinary,
            modelFile: base.modelFile,
            projectorFile: base.projectorFile,
            ablationAdapterFile: base.ablationAdapterFile,
            webUIConfigFile: base.webUIConfigFile,
            chatURL: URL(string: "http://127.0.0.1:\(unusedChatPort)/")!,
            contextSize: base.contextSize,
            reasoningBudget: base.reasoningBudget,
            logDirectory: base.logDirectory
        )
    }

    private func makeDefaults(_ label: String) -> (UserDefaults, String) {
        let suiteName = "Launcher27B-\(label)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        return (defaults, suiteName)
    }

    /// Creates a sparse file of exactly `byteCount` bytes; the installation
    /// inspector accepts a `.file` artifact on size alone, so this is enough to
    /// make an installation look complete without writing 8 GB.
    private func makeSizedFile(at url: URL, byteCount: Int64) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    private func makeReadyRuntime(config: LauncherConfig) throws {
        let runtime = config.serverBinary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        guard FileManager.default.createFile(
            atPath: config.serverBinary.path,
            contents: Data()
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: config.serverBinary.path
        )
        guard FileManager.default.createFile(
            atPath: runtime.appending(path: "libllama-server-impl.dylib").path,
            contents: Data()
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try "\(InstallationCatalog.runtimeRelease)\n".write(
            to: runtime.appending(path: ".llama_release"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Creates every catalog artifact so `refreshInstallationStatus()` resolves
    /// to `.ready`.
    private func makeCompleteInstallation(config: LauncherConfig) throws {
        try makeReadyRuntime(config: config)
        for artifact in InstallationCatalog().artifacts(for: config) {
            guard case .file = artifact.kind else { continue }
            try makeSizedFile(at: artifact.destinationURL, byteCount: artifact.expectedByteCount)
        }
    }

    private func descriptor(pid: pid_t = 4242) -> ServerProcessDescriptor {
        ServerProcessDescriptor(
            pid: pid,
            executablePath: "/tmp/llama-server",
            isManaged: false
        )
    }

    /// The health timeouts are injectable so failure paths resolve in
    /// milliseconds instead of 90 seconds.
    private static let fastHealth = (
        start: Duration.milliseconds(20),
        stop: Duration.milliseconds(20),
        poll: Duration.milliseconds(1)
    )

    // MARK: - Transient failure vs user intent

    @Test
    func supervisionBacksOffWithoutClearingTheUserIntent() {
        var supervision = AutoRestartSupervision()
        let start = ContinuousClock.now

        supervision.intendToRun()
        #expect(supervision.isWanted)

        supervision.recordFailure(at: start)
        #expect(supervision.isWanted)
        #expect(supervision.consecutiveFailures == 1)
        #expect(!supervision.canAttemptStart(at: start))
        #expect(
            supervision.canAttemptStart(
                at: start.advanced(by: AutoRestartSupervision.backoff(forFailureCount: 1))
            )
        )

        supervision.recordSuccess()
        #expect(supervision.consecutiveFailures == 0)
        #expect(supervision.canAttemptStart(at: start))

        // Exhausting the attempt budget pauses supervision, but only an explicit
        // stop clears the intent.
        for _ in 0..<AutoRestartSupervision.maximumConsecutiveFailures {
            supervision.recordFailure(at: start)
        }
        #expect(!supervision.isWanted)
        #expect(
            supervision.consecutiveFailures
                == AutoRestartSupervision.maximumConsecutiveFailures
        )

        supervision.clearIntent()
        #expect(!supervision.isWanted)
        #expect(supervision.consecutiveFailures == 0)
    }

    @Test
    func supervisionBackoffGrowsAndIsCapped() {
        #expect(AutoRestartSupervision.backoff(forFailureCount: 0) == .zero)
        #expect(AutoRestartSupervision.backoff(forFailureCount: 1) == .seconds(5))
        #expect(
            AutoRestartSupervision.backoff(forFailureCount: 2)
                > AutoRestartSupervision.backoff(forFailureCount: 1)
        )
        #expect(
            AutoRestartSupervision.backoff(forFailureCount: 9)
                == AutoRestartSupervision.backoff(forFailureCount: 5)
        )
    }

    /// Verifies the configured backoff delays and maximum retry window.
    @Test
    func theBackoffLadderEndsAt45SecondsBeforeTheBudgetPauses() {
        var supervision = AutoRestartSupervision()
        supervision.intendToRun()
        let start = ContinuousClock.now

        var scheduled: [Duration] = []
        for _ in 1..<AutoRestartSupervision.maximumConsecutiveFailures {
            supervision.recordFailure(at: start)
            #expect(supervision.isWanted)
            scheduled.append(
                AutoRestartSupervision.backoff(
                    forFailureCount: supervision.consecutiveFailures
                )
            )
        }
        #expect(scheduled == [.seconds(5), .seconds(15), .seconds(30), .seconds(45)])

        // The fifth failure pauses instead of waiting out a 60 s tier.
        supervision.recordFailure(at: start)
        #expect(!supervision.isWanted)
        #expect(supervision.retryNotBefore == nil)
    }

    /// A momentary `/health` answer must not clear the failure budget: the
    /// realistic crash loop is a runtime that loads, answers once and then dies
    /// on the first long-context request. Only a server that is *still* healthy
    /// after the stability window earns a reset.
    @Test
    func aMomentaryHealthyReadingDoesNotResetTheFailureBudget() {
        var supervision = AutoRestartSupervision()
        let started = ContinuousClock.now
        supervision.intendToRun()

        supervision.noteHealthy(at: started)
        #expect(supervision.consecutiveFailures == 0)
        #expect(supervision.healthySince == started)

        // It passed `/health` and died 10 s later: that is a failure, not a
        // success…
        supervision.recordCrash(at: started.advanced(by: .seconds(10)))
        #expect(supervision.consecutiveFailures == 1)
        #expect(supervision.healthySince == nil)
        #expect(supervision.isWanted)
        // …and the retry is held back.
        #expect(
            !supervision.canAttemptStart(at: started.advanced(by: .seconds(10)))
        )

        // Two more boot-and-die cycles keep spending the budget.
        for count in 2...3 {
            supervision.noteHealthy(at: started)
            supervision.recordCrash(at: started.advanced(by: .seconds(10)))
            #expect(supervision.consecutiveFailures == count)
        }

        // A server that stays healthy past the window does reset it.
        let stable = started.advanced(by: .seconds(600))
        supervision.intendToRun()
        supervision.noteHealthy(at: stable)
        supervision.recordCrash(at: stable.advanced(by: .seconds(10)))
        #expect(supervision.consecutiveFailures == 1)
        supervision.noteHealthy(at: stable)
        supervision.noteHealthy(
            at: stable.advanced(by: AutoRestartSupervision.defaultStabilityWindow)
        )
        #expect(supervision.consecutiveFailures == 0)
        #expect(supervision.healthySince == stable)
    }

    /// The proven loop: the server answers `/health` and then dies, so the
    /// launcher reloads several gigabytes forever, with `maximumConsecutiveFailures`
    /// never reached and no notice in the UI.
    @Test
    @MainActor
    func aServerThatKeepsDyingAfterHealthPausesInsteadOfReloadingForever() async throws {
        let root = makeRoot("rolling-crash-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("rolling-crash-window")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            // The port answers exactly while the stub process is up, so
            // "healthy and then gone" is modelled faithfully.
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll,
            // No reading in this test is ever "stable": the server always dies
            // before the window elapses, so the budget must keep accumulating.
            stabilityWindow: .seconds(3_600)
        )

        await controller.monitorSetup()
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        // It loads and answers /health …
        await controller.monitorTick1()
        #expect(process.startCallCount == 1)
        #expect(controller.status == .running)
        #expect(controller.consecutiveStartFailures == 0)

        for expected in 1...AutoRestartSupervision.maximumConsecutiveFailures {
            // … and dies on its own (OOM on the first long-context request).
            process.isRunningValue = false
            await controller.monitorTick2()

            #expect(
                controller.consecutiveStartFailures == expected,
                "crash \(expected) was not counted against the budget"
            )
            #expect(controller.status == .stopped)

            guard expected < AutoRestartSupervision.maximumConsecutiveFailures else {
                continue
            }

            // A crash is not followed by an immediate reload: the growing
            // backoff holds the next attempt off.
            let attempts = process.startCallCount
            await controller.monitorTick1()
            #expect(process.startCallCount == attempts)

            // Once the backoff has elapsed the retry reloads the model, and the
            // next crash is counted too.
            await controller.start(userInitiated: false)
            #expect(controller.status == .running)
        }

        // The budget is exhausted: supervision is visibly paused instead of
        // reloading the model again.
        #expect(!controller.isAutoRestartWanted)
        #expect(
            controller.consecutiveStartFailures
                == AutoRestartSupervision.maximumConsecutiveFailures
        )
        // This path pauses on the *start-attempt* budget, which is the evidence
        // that actually ran out, so the reason says so rather than claiming a
        // crash loop.
        #expect(
            controller.supervisionPauseReason
                == .repeatedStartFailures(count: AutoRestartSupervision.maximumConsecutiveFailures)
        )
        let attemptsWhenPaused = process.startCallCount
        await controller.monitorTick1()
        #expect(process.startCallCount == attemptsWhenPaused)
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: controller.consecutiveStartFailures,
                isAutoRestartWanted: controller.isAutoRestartWanted
            ) == .paused(failures: AutoRestartSupervision.maximumConsecutiveFailures)
        )

        // An explicit Start from the user still recovers.
        await controller.start()
        #expect(controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 0)
        #expect(controller.status == .running)
    }

    /// The documented promise is "the launcher restarts the service after an
    /// abnormal exit" — one crash of a server that had been up for a long time
    /// must still be recovered, not treated as a reason to give up.
    @Test
    @MainActor
    func aSingleCrashOfALongRunningServerIsStillRestarted() async throws {
        let root = makeRoot("single-crash-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("single-crash-budget")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll,
            // A zero window stands in for "this server has been healthy far
            // longer than the stability window": any healthy observation has
            // already earned a budget reset.
            stabilityWindow: .zero
        )

        await controller.monitorSetup()
        await controller.monitorTick1()
        #expect(controller.status == .running)

        // The long-running server exits abnormally.
        process.isRunningValue = false
        await controller.monitorTick2()

        // The intent survives and one failure is far short of the budget, so
        // supervision brings it back.
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 1)
        #expect(
            controller.consecutiveStartFailures
                < AutoRestartSupervision.maximumConsecutiveFailures
        )

        await controller.start(userInitiated: false)

        #expect(controller.status == .running)
        #expect(process.startCallCount == 2)
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
    }

    /// A server can answer `/health` and die before the launcher observes it
    /// again. This failure must still spend the retry budget and apply backoff.
    @Test
    @MainActor
    func aCrashImmediatelyAfterHealthStillSpendsTheFailureBudget() async throws {
        let root = makeRoot("crash-before-health-observation")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("crash-before-health-observation")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            // Answers `/health` once and dies before the launcher can observe
            // it again — the OOM/Jetsam shape at load completion.
            healthProbe: { _ in
                guard process.isRunningValue else { return false }
                process.isRunningValue = false
                return true
            },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll,
            stabilityWindow: .seconds(3_600)
        )

        await controller.monitorSetup()
        await controller.monitorTick1()

        #expect(controller.status == .stopped)
        #expect(
            controller.consecutiveStartFailures == 1,
            "a death after /health but before the next sighting was not counted"
        )

        let attemptsAfterCrash = process.startCallCount
        await controller.monitorTick1()
        #expect(
            process.startCallCount == attemptsAfterCrash,
            "the crash was counted but no backoff held the next attempt off"
        )

        // The budget keeps accumulating until supervision pauses.
        for _ in 2...AutoRestartSupervision.maximumConsecutiveFailures {
            await controller.start(userInitiated: false)
        }
        #expect(
            controller.consecutiveStartFailures
                == AutoRestartSupervision.maximumConsecutiveFailures
        )
        #expect(!controller.isAutoRestartWanted)

        let attemptsWhenPaused = process.startCallCount
        await controller.monitorTick1()
        #expect(process.startCallCount == attemptsWhenPaused)
    }

    /// The documented promise, exercised with the *production* 45 s stability
    /// window rather than the `.zero` stand-in the older test used: a server that
    /// has genuinely been up past the window and then crashes once is restarted.
    @Test
    @MainActor
    func aSingleCrashOfAServerThatOutlivedTheProductionWindowIsStillRestarted() async throws {
        let root = makeRoot("production-crash-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("production-crash-window")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let instant = TestInstant()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll,
            stabilityWindow: AutoRestartSupervision.defaultStabilityWindow,
            now: { instant.value }
        )

        await controller.monitorSetup()
        await controller.monitorTick1()
        #expect(controller.status == .running)

        // Well past the production window: this healthy tick legitimately
        // resets the failure budget.
        instant.advance(by: .seconds(60))
        await controller.monitorTick2()
        #expect(controller.consecutiveStartFailures == 0)

        // One crash of a long-running server.
        process.isRunningValue = false
        await controller.monitorTick2()
        #expect(controller.consecutiveStartFailures == 1)
        #expect(controller.isAutoRestartWanted)

        instant.advance(by: AutoRestartSupervision.backoff(forFailureCount: 1))
        await controller.monitorTick1()
        #expect(process.startCallCount == 2)
        #expect(controller.status == .running)
    }

    /// A crash after every stability window resets the consecutive-failure
    /// counter. The rolling crash window must still pause repeated crashes
    /// without stopping after one crash of a stable server.
    @Test
    @MainActor
    func aServerThatAlwaysOutlivesTheStabilityWindowStillPauses() async throws {
        let root = makeRoot("crash-after-stability-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("crash-after-stability-window")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let instant = TestInstant()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll,
            stabilityWindow: AutoRestartSupervision.defaultStabilityWindow,
            now: { instant.value }
        )

        await controller.monitorSetup()
        await controller.monitorTick1()
        #expect(controller.status == .running)

        for cycle in 1...AutoRestartSupervision.maximumCrashesPerWindow {
            // Runs well past the window, so the consecutive budget resets …
            instant.advance(by: .seconds(60))
            await controller.monitorTick2()
            #expect(
                controller.consecutiveStartFailures == 0,
                "a run past the window should still reset the budget"
            )

            // … and then dies.
            process.isRunningValue = false
            await controller.monitorTick2()
            #expect(controller.status == .stopped)

            guard cycle < AutoRestartSupervision.maximumCrashesPerWindow else {
                continue
            }
            #expect(
                controller.isAutoRestartWanted,
                "a single crash of a stable server must not pause supervision"
            )
            await controller.start(userInitiated: false)
            #expect(controller.status == .running)
        }

        // Recurring crashes pause supervision even though every individual run
        // was long enough to look "stable". The failure counter is not the
        // evidence the pause came from — it was reset on every cycle and is 1
        // here — so a notice built from it alone told the user "已连续失败 1 次"
        // and never mentioned the crash loop at all.
        #expect(!controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 1)
        #expect(controller.crashesInCrashWindow == AutoRestartSupervision.maximumCrashesPerWindow)
        #expect(
            controller.supervisionPauseReason
                == .crashLoop(crashesInWindow: AutoRestartSupervision.maximumCrashesPerWindow)
        )
        let attemptsWhenPaused = process.startCallCount
        await controller.monitorTick1()
        #expect(process.startCallCount == attemptsWhenPaused)
    }

    @Test
    @MainActor
    func transientStartFailureKeepsTheRunIntentAndOnlyStopClearsIt() async throws {
        let root = makeRoot("transient-start-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("transient-start-failure")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: false)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        controller.recheckInstallation()
        #expect(controller.installationStatus == .ready)
        await controller.refresh()
        #expect(controller.status == .stopped)

        // A transient start failure must preserve the user's auto-restart intent.
        process.startError = ServerProcessError.healthCheckTimedOut
        await controller.start()

        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(controller.consecutiveStartFailures == 1)
        #expect(controller.isAutoRestartWanted)
        #expect(controller.presentedError != nil)
        #expect(controller.status == .stopped)

        // A second transient failure still keeps the intent. The automatic
        // retry path preserves the failure budget…
        await controller.start(userInitiated: false)
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(controller.consecutiveStartFailures == 2)

        // …and an explicit Start starts the budget over.
        await controller.start()
        #expect(controller.consecutiveStartFailures == 1)

        // Only an explicit Stop clears the user's intent.
        process.isRunningValue = true
        await controller.refresh()
        await controller.stop()

        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(!controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 0)
        #expect(process.stopCallCount == 1)
    }

    @Test
    @MainActor
    func supervisionPausesAfterTheAttemptBudgetIsExhausted() async throws {
        let root = makeRoot("start-retry-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("start-retry-budget")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: false)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        controller.recheckInstallation()
        await controller.refresh()

        process.startError = ServerProcessError.healthCheckTimedOut
        for _ in 0..<AutoRestartSupervision.maximumConsecutiveFailures {
            await controller.start(userInitiated: false)
        }

        #expect(!controller.isAutoRestartWanted)
        #expect(
            controller.consecutiveStartFailures
                == AutoRestartSupervision.maximumConsecutiveFailures
        )
        // The user's intent survives even though supervision gave up.
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        // An explicit Start resets the budget.
        process.startError = nil
        await probe.setValue(true)
        await controller.start()

        #expect(controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 0)
        #expect(controller.status == .running)
    }

    // MARK: - Auto-start with a late-mounting model volume

    @Test
    @MainActor
    func autoStartFiresWhenAnExternalVolumeArrivesAfterLaunch() async throws {
        let root = makeRoot("external-volume-autostart")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        // The configured model location is a symlink to a volume that is not
        // mounted yet, exactly as on a reboot.
        try FileManager.default.createDirectory(
            at: config.modelsDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let volume = root.appending(path: "external-volume", directoryHint: .isDirectory)
        try config.setModelsDirectory(volume)

        let (defaults, suiteName) = makeDefaults("external-volume-autostart")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        #expect(controller.autoStartEnabled)

        await controller.monitorSetup()
        #expect(controller.installationStatus == .failed)
        #expect(controller.status == .stopped)
        // The intent is recorded even though the model is not visible yet.
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        await controller.monitorTick1()
        #expect(process.startCallCount == 0)

        // The external volume mounts and the model becomes ready.
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try makeCompleteInstallation(config: config)
        await controller.monitorTick1()

        #expect(controller.installationStatus == .ready)
        #expect(process.startCallCount == 1)
        #expect(controller.status == .running)
    }

    @Test
    @MainActor
    func autoStartStaysOffWhenTheLoginItemIsDisabled() async throws {
        let root = makeRoot("external-autostart-disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("external-autostart-disabled")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: false)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        #expect(!controller.autoStartEnabled)

        await controller.monitorSetup()
        await controller.monitorTick1()

        #expect(process.startCallCount == 0)
        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))
    }

    // MARK: - install-in-progress gate

    @Test
    @MainActor
    func anInFlightInstallationNeverBecomesReady() async throws {
        let root = makeRoot("install-in-progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("install-in-progress")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = InstallGate()
        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: false)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            installationRunner: { _, _ in
                try await gate.wait()
            },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        controller.recheckInstallation()
        #expect(controller.installationStatus == .required)
        controller.beginInstallation()
        #expect(controller.installationStatus == .installing)

        // The volume is unplugged and replugged and the artifacts appear while
        // the installer is still running.
        try makeCompleteInstallation(config: config)
        controller.refreshInstallationStatus()

        #expect(controller.installationStatus == .installing)
        #expect(!controller.canStart)

        controller.cancelInstallation()
        for _ in 0..<500 where controller.installationStatus == .installing {
            await Task.yield()
        }
        #expect(controller.installationStatus != .installing)
    }

    /// The downloader rewrites the resume marker once a second *while a healthy
    /// transfer runs*, so a marker on disk no longer means "a previous download
    /// can be continued": it also means "a transfer is running here". Before
    /// this, `hasResumableDownload` reported true for the whole download and the
    /// install card offered to "继续下载" the transfer that was already running.
    @Test
    @MainActor
    func aRunningDownloadIsNotReportedAsResumable() async throws {
        let root = makeRoot("resumable-in-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("resumable-in-flight")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A partial left behind by an earlier, interrupted download.
        try FileManager.default.createDirectory(
            at: config.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try DownloadProgressCheckpoint().writeResumeMarker(
            .init(bytes: 1024, validator: "etag"), to: config.resumeDataURL(for: .model)
        )

        let gate = InstallGate()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered },
            installationRunner: { _, _ in
                try await gate.wait()
            }
        )

        controller.recheckInstallation()
        #expect(controller.installationStatus == .required)
        #expect(
            controller.hasResumableDownload,
            "the partial from the interrupted download should be offered to the user"
        )

        controller.beginInstallation()
        #expect(controller.installationStatus == .installing)

        // From here the marker is being rewritten once a second by the running
        // transfer, so it must not read as something to continue.
        #expect(!controller.hasResumableDownload)
        controller.refreshInstallationStatus()
        #expect(!controller.hasResumableDownload)

        controller.cancelInstallation()
        for _ in 0..<500 where controller.installationStatus == .installing {
            await Task.yield()
        }
        #expect(controller.installationStatus != .installing)
    }

    // MARK: - refresh generation counter
    @Test
    @MainActor
    func aStaleRefreshCannotOverwriteANewerStatus() async throws {
        let root = makeRoot("refresh-generation")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("refresh-generation")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: false)
        await probe.parkFirstCall()

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        // The first refresh reads `isRunning() == false` and then parks inside
        // its health probe.
        let stale = Task { await controller.refresh() }
        await process.waitForIsRunningCalls(1)
        await probe.waitForCallCount(1)

        // A newer refresh runs to completion while the first is suspended.
        process.isRunningValue = true
        let fresh = Task { await controller.refresh() }
        await fresh.value
        #expect(controller.status == .starting)

        // Releasing the stale probe must not write `.stopped` over the newer
        // result.
        await probe.resumeFirstCall(with: false)
        await stale.value

        #expect(controller.status == .starting)
    }

    // MARK: - Reachability of an orphaned server

    @Test
    @MainActor
    func aHealthyOrphanRequiresExplicitAdoption() async throws {
        let root = makeRoot("b1-adopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("b1-adopt")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.discovered = descriptor()
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()

        #expect(process.adoptCallCount == 0)
        #expect(controller.status == .external)
        #expect(await controller.adoptUnownedServer())
        #expect(process.adoptCallCount == 1)
        #expect(controller.status == .running)
        #expect(controller.unownedServer == nil)
        #expect(controller.canStop)
    }

    @Test
    @MainActor
    func anUnadoptableHealthyServerCanStillBeStopped() async throws {
        let root = makeRoot("b1-unowned")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("b1-unowned")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.discovered = descriptor()
        process.adoptSucceeds = false
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()

        #expect(controller.status == .external)
        #expect(controller.unownedServer == descriptor())
        #expect(controller.canStopUnownedServer)

        await controller.stopUnownedServer()

        #expect(process.stopDiscoveredCallCount == 1)
        #expect(controller.unownedServer == nil)
    }

    // MARK: - Single instance

    @Test
    @MainActor
    func aSecondInstanceNeitherMonitorsNorAdoptsTheServer() async throws {
        let root = makeRoot("instance")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("instance")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Stand in for the first launcher process by taking the lock on a
        // separate file descriptor.
        let holder = SingleInstanceLock(
            url: SingleInstanceLock.defaultURL(supportDirectory: config.supportDirectory)
        )
        #expect(try holder.acquire() == .acquired)

        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.discovered = descriptor()
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        controller.acquireSingleInstanceLock()

        #expect(controller.instanceLockState == .alreadyRunning(ownerPID: getpid()))
        #expect(!controller.isPrimaryInstance)
        #expect(controller.otherInstanceOwnerPID == getpid())
        #expect(!controller.canStart)
        #expect(!controller.canStop)
        #expect(!controller.canRestart)

        // Neither the periodic supervision nor a refresh may touch the
        // first instance's PID record or run-intent flag.
        controller.startMonitoring()
        await controller.monitorTick1()
        await controller.refresh()

        #expect(process.startCallCount == 0)
        #expect(process.adoptCallCount == 0)
        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        controller.releaseSingleInstanceLock()
        holder.release()
    }

    /// A secondary instance keeps a truthful status snapshot, but its periodic ticks must
    /// be the lock re-check only: re-probing `/health` and `/metrics` (and the
    /// model-location filesystem probe) every two seconds alongside the owner is
    /// pure waste.
    @Test
    @MainActor
    func aSecondaryInstanceDoesNotRefreshOnEveryMonitoringCycle() async throws {
        let root = makeRoot("instance-poll")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("instance-poll")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let holder = SingleInstanceLock(
            url: SingleInstanceLock.defaultURL(supportDirectory: config.supportDirectory)
        )
        #expect(try holder.acquire() == .acquired)

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        controller.recheckInstallation()
        controller.acquireSingleInstanceLock()
        #expect(!controller.isPrimaryInstance)

        // The one setup pass gives the second window an honest status snapshot …
        await controller.monitorSetup()
        let readsAfterSetup = process.isRunningCallCount

        // … and the periodic ticks do not re-read it.
        for _ in 0..<3 {
            await controller.monitorTick2()
        }
        #expect(
            process.isRunningCallCount == readsAfterSetup,
            "a secondary polled the service on every monitoring cycle"
        )
        #expect(!controller.isPrimaryInstance)

        controller.releaseSingleInstanceLock()
        holder.release()
    }

    // MARK: - Quit behaviour

    /// README: "退出启动器时，模型服务继续运行". The only thing the termination
    /// observer does is release the process-wide lock, so a *new* launcher can
    /// take over; it must never signal the managed server.
    @Test
    @MainActor
    func quittingTheLauncherLeavesTheServerRunning() async throws {
        let root = makeRoot("quit")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("quit")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        process.isRunningValue = true
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in true },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        controller.acquireSingleInstanceLock()
        #expect(controller.instanceLockState == .soleInstance)

        // A witness lock stands in for a second launcher waiting its turn.
        let witness = SingleInstanceLock(
            url: SingleInstanceLock.defaultURL(supportDirectory: config.supportDirectory)
        )
        guard case .alreadyRunning = try witness.acquire() else {
            Issue.record("the controller did not hold the instance lock")
            return
        }

        // The app terminates.
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        for _ in 0..<50 {
            await Task.yield()
        }

        // The lock was released so a new launcher can take over …
        #expect(try witness.acquire() == .acquired)
        // … and the managed server was never signalled.
        #expect(process.stopCallCount == 0)

        witness.release()
        controller.releaseSingleInstanceLock()
    }

    // MARK: - Hardware preflight

    @Test
    @MainActor
    func anUnsupportedMacIsRefusedBeforeTheDownload() async throws {
        let root = makeRoot("hardware")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("hardware")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered },
            hardwareRequirements: HardwareRequirements(
                architecture: "x86_64",
                physicalMemoryBytes: 32 * 1_073_741_824
            )
        )

        #expect(!controller.canInstallModel)
        #expect(controller.hardwareIssueMessage?.contains("处理器") == true)

        controller.recheckInstallation()
        #expect(controller.installationStatus == .required)

        controller.beginInstallation()

        #expect(controller.installationStatus == .failed)
        #expect(controller.installationError?.contains("处理器") == true)
    }

    @Test
    @MainActor
    func lowMemoryIsAWarningRatherThanABlocker() async throws {
        let root = makeRoot("hardware-warning")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("hardware-warning")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered },
            hardwareRequirements: HardwareRequirements(
                architecture: "arm64",
                physicalMemoryBytes: 20 * 1_073_741_824
            )
        )

        #expect(controller.canInstallModel)
        #expect(controller.hardwareIssueMessage?.contains("内存偏低") == true)
    }

    // MARK: - LAN binding confirmation and chat availability

    @Test
    @MainActor
    func lanBindingRequiresExplicitConfirmation() async throws {
        let root = makeRoot("bind")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("bind")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered }
        )

        #expect(controller.bindMode == .loopback)
        #expect(controller.canOpenChat)
        #expect(!controller.isBindModeChangePending)

        await controller.setBindMode(.allInterfaces)
        #expect(controller.bindMode == .loopback)
        #expect(controller.pendingBindMode == .allInterfaces)
        #expect(controller.isBindModeChangePending)

        await controller.confirmBindMode(.allInterfaces)
        #expect(controller.bindMode == .allInterfaces)
        #expect(controller.pendingBindMode == nil)
        #expect(!controller.canOpenChat)

        // Switching back to loopback is safe and applies immediately.
        await controller.setBindMode(.loopback)
        #expect(controller.bindMode == .loopback)
        #expect(controller.canOpenChat)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor
    func lanConfirmationSurvivesDialogDismissal(running: Bool, dismissBeforeAction: Bool) async throws {
        let root = makeRoot("bind-dismissal")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)
        let (defaults, suiteName) = makeDefaults("bind-dismissal")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let process = StubServerProcessManager()
        let controller = ServiceController(config: config, requiresInstanceLock: false,
            preferences: TestPreferences.chinese(), processManager: process, defaults: defaults,
            healthProbe: { _ in process.isRunningValue }, loginItemStatus: { .notRegistered })
        await controller.monitorSetup()
        if running { await controller.start() }
        await controller.setBindMode(.allInterfaces)
        #expect(controller.pendingBindMode == .allInterfaces)
        let presentedMode = try #require(controller.pendingBindMode)
        // SwiftUI can dismiss the dialog before the button's async task runs.
        if dismissBeforeAction { controller.cancelPendingBindMode() }
        let confirmation = Task { await controller.confirmBindMode(presentedMode) }
        if !dismissBeforeAction { controller.cancelPendingBindMode() }
        await confirmation.value
        #expect(controller.bindMode == .allInterfaces)
        #expect(defaults.string(forKey: "serverBindMode") == ServerBindMode.allInterfaces.rawValue)
        #expect(!controller.isBindModeChangePending)
        #expect(!controller.isBusy)
        #expect(process.startCallCount == (running ? 2 : 0))
        #expect(process.stopCallCount == (running ? 1 : 0))
        if running { #expect(controller.effectiveBindMode == .allInterfaces) }
    }

    @Test
    @MainActor
    func dismissingLANConfirmationDoesNotChangeScope() async throws {
        let root = makeRoot("bind-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults("bind-cancel")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let process = StubServerProcessManager()
        let controller = ServiceController(config: makeConfig(root: root), requiresInstanceLock: false,
            preferences: TestPreferences.chinese(), processManager: process, defaults: defaults,
            healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        await controller.setBindMode(.allInterfaces)
        controller.cancelPendingBindMode()
        await Task.yield()
        #expect(controller.bindMode == .loopback)
        #expect(!controller.isBindModeChangePending)
        #expect(defaults.string(forKey: "serverBindMode") != ServerBindMode.allInterfaces.rawValue)
        #expect(process.startCallCount == 0)
        #expect(process.stopCallCount == 0)
    }

    // MARK: - Model migration intent

    /// `performModelMigration` stops the service on the way to copying the
    /// models, and `stop()` is what persists "the user asked to stop". A quit or
    /// a crash during the copy can leave that off-state behind, so the next
    /// launch restores the run intent that was active before migration.
    @Test
    @MainActor
    func anInterruptedModelMigrationIsReconciledOnTheNextLaunch() async throws {
        let root = makeRoot("interrupted-migration-reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("interrupted-migration-reconcile")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Exactly the state an interrupted migration leaves on disk: the
        // internal stop() has written the run intent off, and the record made
        // just before it is the only trace of the user's intent.
        defaults.set(false, forKey: "bonsaiShouldKeepRunning")
        defaults.set(true, forKey: "bonsaiRunIntentBeforeMigration")

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered }
        )

        await controller.monitorSetup()

        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(controller.isAutoRestartWanted)
        #expect(defaults.object(forKey: "bonsaiRunIntentBeforeMigration") == nil)
    }

    /// The record has to be written *before* the stop, or the crash window it
    /// exists to cover is still open.
    @Test
    @MainActor
    func theRunIntentIsRecordedBeforeAMigrationStopsTheService() async throws {
        let root = makeRoot("migration-run-intent-record")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("migration-run-intent-record")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let destination = root.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = StubServerProcessManager()
        let probe = StubHealthProbe(value: true)
        process.isRunningValue = true
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        controller.recheckInstallation()
        defaults.set(true, forKey: "bonsaiShouldKeepRunning")
        await controller.refresh()
        #expect(controller.status == .running)

        // Park the migration inside the stop it performs, so the test can look
        // at what a quit at that instant would leave behind.
        let gate = InstallGate()
        process.stopHook = { try? await gate.wait() }

        controller.beginModelMigration(to: destination)
        for _ in 0..<2_000 where process.stopCallCount == 0 {
            await Task.yield()
        }
        #expect(process.stopCallCount == 1)

        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))
        #expect(defaults.bool(forKey: "bonsaiRunIntentBeforeMigration"))

        // Once the migration ends the record is consumed and the intent is put
        // back. The migration may take a real pause waiting for the port to go
        // quiet, so wait on the record with a wall-clock deadline rather than a
        // fixed number of yields.
        await gate.cancel()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while defaults.object(forKey: "bonsaiRunIntentBeforeMigration") != nil,
              ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(defaults.object(forKey: "bonsaiRunIntentBeforeMigration") == nil)
        #expect(defaults.bool(forKey: "bonsaiShouldKeepRunning"))
    }

    // MARK: - Instance takeover

    /// A second instance that did not acquire the lock at launch can become
    /// primary after the first instance exits.
    @Test
    @MainActor
    func aSecondInstanceBecomesPrimaryAfterTheFirstReleasesTheLock() async throws {
        let root = makeRoot("secondary-instance-takeover")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("secondary-instance-takeover")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let holder = SingleInstanceLock(
            url: SingleInstanceLock.defaultURL(supportDirectory: config.supportDirectory)
        )
        #expect(try holder.acquire() == .acquired)

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered }
        )
        controller.recheckInstallation()
        controller.acquireSingleInstanceLock()

        #expect(controller.instanceLockState == .alreadyRunning(ownerPID: getpid()))
        #expect(!controller.isPrimaryInstance)
        #expect(!controller.canStart)

        await controller.refresh()
        #expect(controller.status == .stopped)

        // The first launcher quits.
        holder.release()
        await controller.monitorTick2()

        #expect(controller.instanceLockState == .soleInstance)
        #expect(controller.isPrimaryInstance)
        #expect(controller.otherInstanceOwnerPID == nil)
        #expect(controller.canStart)

        controller.releaseSingleInstanceLock()
    }

    /// Taking over is not a relaunch. If the first launcher's user pressed Stop,
    /// the persisted intent is off; a second instance that acquires the lock
    /// must not manufacture intent from the login item and start the server the
    /// user just stopped — silently, with no relaunch to explain it.
    @Test
    @MainActor
    func aTakeoverDoesNotResurrectAServerTheUserStopped() async throws {
        let root = makeRoot("secondary-instance-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("secondary-instance-stop")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The user pressed Stop before quitting the first launcher.
        defaults.set(false, forKey: "bonsaiShouldKeepRunning")

        let holder = SingleInstanceLock(
            url: SingleInstanceLock.defaultURL(supportDirectory: config.supportDirectory)
        )
        #expect(try holder.acquire() == .acquired)

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .enabled },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )
        controller.recheckInstallation()
        controller.acquireSingleInstanceLock()

        #expect(!controller.isPrimaryInstance)
        #expect(controller.autoStartEnabled)

        await controller.monitorSetup()
        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        // The first launcher quits and this one takes over.
        holder.release()
        await controller.monitorTick2()
        #expect(controller.isPrimaryInstance)

        #expect(!controller.isAutoRestartWanted)
        #expect(!defaults.bool(forKey: "bonsaiShouldKeepRunning"))

        await controller.monitorTick1()
        #expect(process.startCallCount == 0)

        controller.releaseSingleInstanceLock()
    }

    // MARK: - Running launch options

    /// The scope of the *running* server is what matters. Switching the
    /// preference back to loopback only restarts the service afterwards, so a
    /// a failed stop can leave a `--no-webui` server alive, so the UI must not
    /// offer "open chat" until the running scope changes.
    @Test
    @MainActor
    func aRunningLanServerKeepsItsScopeWhenTheBindPreferenceFlipsBack() async throws {
        let root = makeRoot("live-bind-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)
        try makeCompleteInstallation(config: config)

        let (defaults, suiteName) = makeDefaults("live-bind-scope")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let process = StubServerProcessManager()
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .notRegistered },
            healthStartTimeout: Self.fastHealth.start,
            healthStopTimeout: Self.fastHealth.stop,
            healthPollInterval: Self.fastHealth.poll
        )

        controller.recheckInstallation()
        await controller.refresh()
        #expect(controller.status == .stopped)

        await controller.setBindMode(.allInterfaces, confirmed: true)
        #expect(controller.bindMode == .allInterfaces)

        await controller.start()
        #expect(controller.status == .running)
        #expect(controller.effectiveBindMode == .allInterfaces)
        #expect(!controller.canOpenChat)

        // The user switches back to loopback, but the stop fails, so the
        // `--no-webui` server is the one still running.
        process.stopError = ServerProcessError.signalFailed(errno: EPERM)
        await controller.setBindMode(.loopback)

        #expect(controller.bindMode == .loopback)
        #expect(controller.status == .running)
        #expect(controller.effectiveBindMode == .allInterfaces)
        #expect(!controller.canOpenChat)

        // With nothing running, the preference governs again.
        process.stopError = nil
        await controller.stop()
        #expect(controller.effectiveBindMode == .loopback)
        #expect(controller.canOpenChat)
    }

    /// A controller with no recorded launch options — it never called `start()`
    /// for the server that is up, and nothing was persisted for it — must report
    /// the options as unknown instead of trusting the preference. The record is
    /// written by the launch itself, so this is the adopted / foreign-server
    /// case: a `--no-webui` server can be running while the preference says
    /// loopback, and the view must be able to tell.
    @Test
    @MainActor
    func aRunningServerThisProcessDidNotStartHasUnknownLaunchOptions() async throws {
        let root = makeRoot("unknown-options")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)

        let (defaults, suiteName) = makeDefaults("unknown-options")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A server started by a previous launcher process: it is running and
        // healthy, but this controller never called `start()`.
        let process = StubServerProcessManager()
        process.isRunningValue = true
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { _ in true },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()

        #expect(controller.status == .running)
        #expect(controller.activeLaunchOptions == nil)
        #expect(controller.runningServerOptionsAreUnknown)
        #expect(controller.effectiveBindMode == nil)

        // Once nothing is running there is no live server to mis-describe.
        process.isRunningValue = false
        await controller.refresh()
        #expect(!controller.runningServerOptionsAreUnknown)
    }

    // MARK: - Foreign port owner

    /// A healthy port owned by something that is not our binary still has to be
    /// reachable from the UI: identified by port so it can be explained and
    /// stopped, and never adoptable.
    @Test
    @MainActor
    func aHealthyForeignListenerIsIdentifiedAndStoppableButNotAdoptable() async throws {
        let root = makeRoot("foreign-port-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)

        let (defaults, suiteName) = makeDefaults("foreign-port-owner")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let foreign = ServerProcessDescriptor(
            pid: 777,
            executablePath: "/opt/homebrew/bin/llama-server",
            isManaged: false
        )
        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.discovered = nil
        process.portListenerValue = foreign
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()

        #expect(controller.status == .external)
        #expect(controller.unownedServer == foreign)
        #expect(controller.unownedServerIsForeign)
        #expect(controller.canStopUnownedServer)

        // It cannot be adopted — it is not the launcher's binary …
        #expect(await controller.adoptUnownedServer() == false)
        // … but it can be stopped, and the port-specific path is used.
        await controller.stopUnownedServer()
        #expect(process.stopPortListenerCallCount == 1)
        #expect(process.stopDiscoveredCallCount == 0)
        #expect(controller.unownedServer == nil)
        #expect(!controller.canStopUnownedServer)
    }

    /// A published foreign listener that *exits* must stop being published.
    ///
    /// Clear `unownedServer` when a foreign listener exits, even if neither the
    /// adoption path nor the managed-process path is active, so the UI cannot
    /// display a stale PID or an enabled stop button for a dead process.
    @Test
    @MainActor
    func aForeignListenerThatExitsStopsBeingPublished() async throws {
        let root = makeRoot("foreign-listener-exit")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root, unusedChatPort: 1)

        let (defaults, suiteName) = makeDefaults("foreign-listener-exit")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let foreign = ServerProcessDescriptor(
            pid: 777,
            executablePath: "/opt/homebrew/bin/llama-server",
            isManaged: false
        )
        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.discovered = nil
        process.portListenerValue = foreign
        let probe = StubHealthProbe(value: true)
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: process,
            defaults: defaults,
            healthProbe: { url in await probe.probe(url) },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()
        #expect(controller.status == .external)
        #expect(controller.unownedServer == foreign)
        #expect(controller.unownedServerIsForeign)
        #expect(controller.canStopUnownedServer)

        // The foreign process exits and the port stops answering: nothing of ours
        // is running and nothing is healthy, so the listener is gone too.
        await probe.setValue(false)
        await controller.refresh()

        #expect(controller.status == .stopped)
        #expect(controller.unownedServer == nil)
        #expect(!controller.unownedServerIsForeign)
        #expect(!controller.canStopUnownedServer)
    }

    // MARK: - Error surfacing

    @Test
    @MainActor
    func theNewestErrorSurvivesDismissal() async throws {
        let root = makeRoot("error-surfacing")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("error-surfacing")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered }
        )

        controller.presentedError = "一个较早的错误"
        controller.acknowledgePresentedError()
        #expect(!controller.hasPresentedError)

        controller.revealModels()
        #expect(controller.hasPresentedError)
        #expect(controller.latestError == "模型存储位置当前不可用")

        controller.acknowledgePresentedError()
        #expect(!controller.hasPresentedError)
        // The message is still available for the view to surface when the
        // window is reopened.
        #expect(controller.latestError == "模型存储位置当前不可用")
    }

    @Test
    @MainActor
    func rawSystemErrorsAreMappedToLocalizedMessages() async throws {
        let root = makeRoot("localized-error-mapping")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = makeConfig(root: root)

        let (defaults, suiteName) = makeDefaults("localized-error-mapping")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: StubServerProcessManager(),
            defaults: defaults,
            healthProbe: { _ in false },
            loginItemStatus: { .notRegistered }
        )

        // SMAppService failures (app not in /Applications, quarantined,
        // App-Translocated) arrive as this raw NSError.
        let registration = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        let registrationMessage = controller.localizedMessage(for: registration)
        #expect(registrationMessage.contains("开机启动"))
        #expect(!registrationMessage.contains("Operation not permitted"))

        #expect(
            controller.localizedMessage(
                for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            ).contains("磁盘空间不足")
        )
        #expect(
            controller.localizedMessage(
                for: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            ).contains("权限")
        )
        #expect(
            controller.localizedMessage(
                for: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
            ).contains("找不到")
        )
        #expect(
            controller.localizedMessage(
                for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
            ).contains("只读")
        )

        // App errors keep their existing two-tier rendering.
        #expect(
            controller.localizedMessage(for: ServerProcessError.forceStopTimedOut)
                .contains("未能")
        )
    }
}
