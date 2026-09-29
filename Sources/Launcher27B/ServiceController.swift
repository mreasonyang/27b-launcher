import AppKit
import Darwin
import Foundation
import Observation
import ServiceManagement

/// The process operations the controller drives.
///
/// Extracted from ``ServerProcessManager`` so supervision (auto-start,
/// auto-restart, orphan adoption) can be exercised in tests without launching a
/// real `llama-server`.
protocol ServerProcessControlling: Sendable {
    func logMaintenanceFailure() async -> String?
    func runningLaunchOptions() async -> ServerLaunchOptions?
    func isRunning() async -> Bool
    func start(options: ServerLaunchOptions) async throws
    func stop() async throws
    func discoverRunningServer() async -> ServerProcessDescriptor?
    @discardableResult func adoptDiscoveredServer() async -> ServerProcessDescriptor?
    func stopDiscoveredServer() async throws
    /// The process listening on the launcher's port, whatever binary it is.
    func portListener() async -> ServerProcessDescriptor?
    /// Stops that process after re-identifying it; it is never the launcher's
    /// own runtime binary.
    func stopPortListener(_ expected: ServerProcessDescriptor) async throws
}

extension ServerProcessControlling {
    func logMaintenanceFailure() async -> String? { nil }
}

extension ServerProcessManager: ServerProcessControlling {}

/// Supervision policy behind the documented "restart the server after an
/// abnormal exit" behaviour.
///
/// This type deliberately holds only *transient* supervision state. The user's
/// persisted intent lives in `UserDefaults` and is cleared by an explicit Stop
/// alone, so a single transient failure (busy machine, port not yet released,
/// external volume still mounting) can no longer permanently disable crash
/// recovery while the UI still claims the feature is on.
/// Why supervision stopped retrying, so the UI can explain the *real* evidence.
///
/// The consecutive-failure counter alone cannot describe a crash loop: a server
/// whose runs each outlive ``AutoRestartSupervision/defaultStabilityWindow``
/// earns a budget reset on every cycle, so the pause arrives with
/// `consecutiveFailures == 1`. A notice built from the counter alone would tell
/// the user a single failure happened and never mention the crash loop that
/// actually did, which is the only signal the crash-rate path ever gives.
enum SupervisionPauseReason: Sendable, Equatable {
    /// Start attempt after start attempt never reached `/health`.
    case repeatedStartFailures(count: Int)
    /// The server kept crashing *after* having been observed healthy.
    ///
    /// `crashesInWindow` is how many crashes are still inside
    /// ``AutoRestartSupervision/crashRateWindow``.
    case crashLoop(crashesInWindow: Int)
}

struct AutoRestartSupervision: Equatable {
    /// After this many consecutive failures supervision pauses and waits for an
    /// explicit Start from the user.
    static let maximumConsecutiveFailures = 5

    /// How long a server must stay healthy before its uptime is allowed to
    /// clear the failure budget.
    ///
    /// A single `/health` answer proves only that the process loaded *once* —
    /// exactly the state an OOM/Jetsam-killed server passes through on its way
    /// out. If a momentary healthy reading reset the budget, a runtime that
    /// loads, answers `/health` and then dies would be reloaded (several GB)
    /// forever without ever reaching ``maximumConsecutiveFailures``.
    static let defaultStabilityWindow = Duration.seconds(45)

    /// Crashes older than this stop counting towards ``maximumCrashesPerWindow``.
    static let crashRateWindow = Duration.seconds(600)

    /// How many crashes inside ``crashRateWindow`` mark the server as looping
    /// even when each individual run outlived the stability window.
    ///
    /// A server that crashes every ~50 s resets ``consecutiveFailures`` on every
    /// healthy tick past the 45 s window, so the counter never rises above 1 and
    /// the budget alone never pauses it. The window catches exactly that shape
    /// while leaving the documented promise intact: a genuinely stable server
    /// that crashes *once* is still far below this count and is restarted.
    static let maximumCrashesPerWindow = 3

    private(set) var consecutiveFailures = 0
    /// True while supervision should (re)start the server whenever it is stopped.
    private(set) var isWanted = false
    private(set) var retryNotBefore: ContinuousClock.Instant?
    /// When the running server was first seen healthy and has not crashed since.
    private(set) var healthySince: ContinuousClock.Instant?
    /// Crash timestamps still inside ``crashRateWindow``. Deliberately *not*
    /// cleared by ``recordSuccess()``: that reset is what let an always-slow
    /// crash loop hide from the budget.
    private(set) var recentCrashes: [ContinuousClock.Instant] = []
    /// Why supervision paused, or `nil` while it is still retrying. Set on the
    /// same transition that clears ``isWanted``, so the view never has to infer
    /// the reason from a counter that understates it.
    private(set) var pauseReason: SupervisionPauseReason?
    /// Injectable so the crash-after-healthy loop can be exercised without
    /// waiting out the production 45 s window.
    var stabilityWindow = AutoRestartSupervision.defaultStabilityWindow

    /// Delay before the next attempt after `count` consecutive failures.
    ///
    /// The ladder the running controller actually walks is 5 s, 15 s, 30 s and
    /// 45 s: the fifth consecutive failure exhausts ``maximumConsecutiveFailures``
    /// and pauses supervision instead of scheduling another retry, so the 60 s
    /// tier is never scheduled from ``recordFailure(at:)``. It is kept as the
    /// saturation value for direct callers of this function.
    static func backoff(forFailureCount count: Int) -> Duration {
        switch count {
        case ..<1: .zero
        case 1: .seconds(5)
        case 2: .seconds(15)
        case 3: .seconds(30)
        case 4: .seconds(45)
        default: .seconds(60)
        }
    }

    /// The user (or the login item) asked for the server to run. Used when the
    /// request is fresh — launch, login item, or an explicit Start — so the
    /// failure budget starts over.
    mutating func intendToRun() {
        isWanted = true
        consecutiveFailures = 0
        retryNotBefore = nil
        healthySince = nil
        recentCrashes.removeAll()
        pauseReason = nil
    }

    /// Supervision still wants the server up, but this is an automatic retry, so
    /// the consecutive-failure budget is preserved.
    mutating func noteWanted() {
        isWanted = true
        retryNotBefore = nil
    }

    /// The user explicitly stopped the server. Only this clears the intent.
    mutating func clearIntent() {
        isWanted = false
        consecutiveFailures = 0
        retryNotBefore = nil
        healthySince = nil
        recentCrashes.removeAll()
        pauseReason = nil
    }

    /// The server answered `/health` just now.
    ///
    /// This only opens (or keeps) the uptime window; ``recordSuccess()`` — the
    /// budget reset — is reserved for a server that is *still* healthy one
    /// ``stabilityWindow`` later.
    mutating func noteHealthy(at now: ContinuousClock.Instant) {
        isWanted = true
        guard let since = healthySince else {
            healthySince = now
            return
        }
        guard now >= since.advanced(by: stabilityWindow) else { return }
        recordSuccess()
    }

    mutating func recordSuccess() {
        isWanted = true
        consecutiveFailures = 0
        retryNotBefore = nil
        pauseReason = nil
        // `recentCrashes` is intentionally left alone. Clearing it here is what
        // let a server whose runs each outlived the stability window (crash at
        // T+50 s, reset, reload, crash again) hide from the budget forever; the
        // rolling window is the only thing that sees it.
    }

    /// A start attempt failed: the server never became healthy, so this is a
    /// transient/bootstrap failure rather than a crash. The rolling crash window
    /// deliberately does not see it, so a port that takes several retries to be
    /// released still gets the full five-attempt budget.
    mutating func recordFailure(at now: ContinuousClock.Instant) {
        record(at: now, isCrash: false)
    }

    /// A server that had been healthy exited on its own.
    ///
    /// Counted both against the consecutive budget and against
    /// ``maximumCrashesPerWindow``, because a server whose runs each outlive the
    /// stability window resets the budget on every cycle and is otherwise never
    /// paused.
    mutating func recordCrash(at now: ContinuousClock.Instant) {
        record(at: now, isCrash: true)
    }

    private mutating func record(at now: ContinuousClock.Instant, isCrash: Bool) {
        healthySince = nil
        consecutiveFailures += 1
        if isCrash {
            recentCrashes.append(now)
            recentCrashes.removeAll { now > $0.advanced(by: Self.crashRateWindow) }
        }

        let failuresExhausted = consecutiveFailures >= Self.maximumConsecutiveFailures
        let crashLoop = recentCrashes.count >= Self.maximumCrashesPerWindow
        guard !failuresExhausted, !crashLoop else {
            isWanted = false
            retryNotBefore = nil
            // Record *which* evidence paused supervision. The counter alone
            // understates a slow crash loop (it pauses with one counted
            // failure), so the view cannot recover the reason by itself.
            pauseReason = failuresExhausted
                ? .repeatedStartFailures(count: consecutiveFailures)
                : .crashLoop(crashesInWindow: recentCrashes.count)
            return
        }
        isWanted = true
        pauseReason = nil
        retryNotBefore = now.advanced(
            by: Self.backoff(forFailureCount: consecutiveFailures)
        )
    }

    func canAttemptStart(at now: ContinuousClock.Instant) -> Bool {
        guard isWanted else { return false }
        guard let retryNotBefore else { return true }
        return now >= retryNotBefore
    }
}

/// Outcome of the process-wide single-instance guard.
enum LauncherInstanceLockState: Sendable, Equatable {
    /// ``ServiceController/acquireSingleInstanceLock()`` has not run yet.
    case notAcquired
    case soleInstance
    /// Another live launcher process owns the lock; this instance must not
    /// touch `bonsaiServerPID` or the run-intent flag.
    case alreadyRunning(ownerPID: pid_t)
    /// The lock file could not be created; mutations remain disabled.
    case unavailable
}

@MainActor
@Observable
final class ServiceController {
    private(set) var quickStartPresented = false
    private(set) var isPreparingQuickStart = false
    private(set) var chatOpenError: String?
    private(set) var connectionModelID: String?
    private(set) var connectionModelIDFailed = false
    private let modelIdentifierLoader: @Sendable (URL) async throws -> String
    private(set) var installationSpace: [InstallationVolumeSpace]?
    private(set) var installationSpaceError: String?
    private var spaceCheckGeneration = 0
    private var prepareAfterInstallation = false
    private let openChatURL: (URL) -> Bool
    private let spaceReporter: @Sendable ([InstallationArtifact]) async throws -> [InstallationVolumeSpace]

    private(set) var status: ServiceStatus = .checking
    private(set) var installationStatus: InstallationStatus = .checking
    private(set) var missingArtifacts: [InstallationArtifact] = []
    private(set) var reusedArtifacts: [InstallationArtifact] = []
    private(set) var installationProgress: InstallationProgress?
    private(set) var installationError: String?
    private(set) var hasResumableDownload = false
    private(set) var isCancellingInstallation = false
    private(set) var autoStartEnabled = false
    private(set) var loginItemRequiresApproval = false
    private(set) var isBusy = false
    private(set) var ablationEnabled = true
    private(set) var ablationStrength: AblationStrength = .defaultValue
    private(set) var bindMode: ServerBindMode = .loopback
    private(set) var tokenUsage: TokenUsageSnapshot?
    private(set) var modelStorageURL: URL
    private(set) var modelStorageBytes: Int64 = 0
    private(set) var modelStorageIsAvailable = false
    private(set) var modelStorageConfigurationUnavailable = false
    private(set) var isModelMigrationInProgress = false
    private(set) var isCancellingModelMigration = false
    private(set) var modelMigrationProgress: ModelStorageMigrationProgress?
    private(set) var modelMigrationOutcome: ModelStorageMigrationOutcome?

    private(set) var modelStorageNotice: ModelStorageMigrationNotice?

    /// The old model location a completed migration could not delete, so the
    /// duplicate stays visible after the app is quit and reopened.
    ///
    /// Persisted in model-location.json and re-validated against the file system on
    /// every storage refresh: it explains disk usage that nothing else in the UI
    /// mentions once the in-memory ``modelMigrationOutcome`` is gone.
    private(set) var retainedSourceModelLocation: URL?
    private(set) var retainedSourceModelBytes: Int64 = 0

    /// A healthy server on the launcher's port that could not be adopted, so the
    /// view can still explain the conflict and offer to stop it.
    ///
    /// Also set when the listener is *not* the launcher's binary at all and was
    /// identified through the port, so the card still offers an explanation and
    /// a stop path instead of a dead end.
    private(set) var unownedServer: ServerProcessDescriptor?

    /// True when ``unownedServer`` was found by listening port rather than by
    /// executable path: it can be stopped but never adopted, and the view must
    /// not offer "take over" for it.
    private(set) var unownedServerIsForeign = false

    /// The options the *running* server was actually launched with, or `nil`
    /// when the launcher is not managing a running process.
    ///
    /// The bind-mode preference can differ from this: switching back to loopback
    /// flips the preference first and only then restarts, so a restart that
    /// fails leaves a `--no-webui` server running while the preference says
    /// loopback.
    private(set) var activeLaunchOptions: ServerLaunchOptions?

    /// The LAN binding awaiting explicit user confirmation, if any.
    private(set) var pendingBindMode: ServerBindMode?

    /// Process-wide instance guard state, so the view can warn that a second
    /// launcher is running.
    private(set) var instanceLockState: LauncherInstanceLockState = .notAcquired

    /// Newest error message, kept even after the alert is dismissed because the
    /// app keeps running with no window open.
    private(set) var latestError: String?

    /// Currently alerting error. Assigning `nil` dismisses the alert.
    var presentedError: String?

    let config: LauncherConfig

    private let processManager: any ServerProcessControlling
    private let preferences: AppPreferences
    private let installationCatalog: InstallationCatalog
    private let installationInspector: InstallationInspector
    private let modelStorageManager: ModelStorageManager
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let metricsClient: LlamaMetricsClient
    private let openDirectory: (URL) -> Bool
    private let healthProbe: @Sendable (URL) async -> Bool
    private let loginItemStatus: @Sendable () -> SMAppService.Status
    private let hardwareRequirements: HardwareRequirements
    private let installationRunner: InstallationRunner
    /// How long a start waits for the server to answer `/health`.
    private let healthStartTimeout: Duration
    /// How long a stop waits for the port to stop answering.
    private let healthStopTimeout: Duration
    private let healthPollInterval: Duration
    private var currentOperation: ServiceOperation?
    private var installationTask: Task<Void, Never>?
    private var modelMigrationTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false
    /// What the managed server was launched with, as persisted at launch.
    ///
    /// ``activeLaunchOptions`` alone is in-memory, while
    /// `ServerProcessManager` deliberately persists the child PID so quitting
    /// the launcher leaves the model running. Without this record the next
    /// launch saw *its own* server as an unknown one and hid the chat
    /// affordance in the app's most common flow. Re-validated against the
    /// process manager on every refresh: adopted servers never use it.
    private var requiresInstanceLock: Bool
    private var supervision: AutoRestartSupervision
    private var instanceLock: SingleInstanceLock?
    private var terminationObserver: NSObjectProtocol?
    /// Reads the time supervision timestamps are compared against. Injectable so
    /// the production stability window and crash-rate window can be driven
    /// without real sleeps.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// Bumped by every ``refresh()`` so a slower in-flight refresh cannot write a
    /// stale status over a newer one.
    private var refreshGeneration = 0

    /// Performs the artifact download. Injectable so tests can simulate an
    /// in-flight installation without transferring 8 GB.
    typealias InstallationRunner = @Sendable (
        [InstallationArtifact],
        @escaping @Sendable (InstallationProgress) async -> Void
    ) async throws -> Void

    private static let shouldRunKey = "bonsaiShouldKeepRunning"
    /// The run intent recorded immediately before a model migration stops the
    /// service, so a quit or crash during the copy cannot discard it.
    private static let interruptedMigrationIntentKey = "bonsaiRunIntentBeforeMigration"
    private static let ablationEnabledKey = "orcabonsaiAblationEnabled"
    private static let ablationStrengthKey = "orcabonsaiAblationStrength"
    private static let bindModeKey = "serverBindMode"
    /// The options the managed server was launched with, as
    /// `["bindMode": String, "ablationEnabled": Bool, "ablationStrength": String]`.
    /// Not a secret: it only mirrors values that already live in the
    /// preferences, and it exists so a reopened launcher still recognises the
    /// server it started itself.

    private static let appServiceErrorDomain = "SMAppServiceErrorDomain"

    init(
        config: LauncherConfig,
        requiresInstanceLock: Bool = true,
        preferences: AppPreferences = AppPreferences(),
        processManager: (any ServerProcessControlling)? = nil,
        metricsClient: LlamaMetricsClient = LlamaMetricsClient(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        openDirectory: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        openChatURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        modelIdentifierLoader: @escaping @Sendable (URL) async throws -> String = { try await LocalModelCatalog().modelID(baseURL: $0) },
        spaceReporter: (@Sendable ([InstallationArtifact]) async throws -> [InstallationVolumeSpace])? = nil,
        healthProbe: @escaping @Sendable (URL) async -> Bool = ServiceController.probeHealth,
        loginItemStatus: @escaping @Sendable () -> SMAppService.Status = {
            SMAppService.mainApp.status
        },
        hardwareRequirements: HardwareRequirements = .current(),
        installationRunner: InstallationRunner? = nil,
        healthStartTimeout: Duration = .seconds(90),
        healthStopTimeout: Duration = .seconds(20),
        healthPollInterval: Duration = .seconds(1),
        stabilityWindow: Duration = AutoRestartSupervision.defaultStabilityWindow,
        now: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        self.config = config
        self.requiresInstanceLock = requiresInstanceLock
        self.preferences = preferences
        self.processManager = processManager ?? ServerProcessManager(config: config)
        self.metricsClient = metricsClient
        let installationCatalog = InstallationCatalog()
        self.installationCatalog = installationCatalog
        self.installationInspector = InstallationInspector()
        self.modelStorageManager = ModelStorageManager(
            config: config,
            artifacts: installationCatalog.artifacts(for: config)
        )
        self.fileManager = fileManager
        self.defaults = defaults
        self.openDirectory = openDirectory
        self.openChatURL = openChatURL
        self.modelIdentifierLoader = modelIdentifierLoader
        self.spaceReporter = spaceReporter ?? { artifacts in
            try await BonsaiInstaller(config: config).diskSpaceReport(for: artifacts)
        }
        self.healthProbe = healthProbe
        self.loginItemStatus = loginItemStatus
        self.hardwareRequirements = hardwareRequirements
        self.installationRunner = installationRunner ?? { artifacts, progress in
            try await BonsaiInstaller(config: config).install(
                artifacts: artifacts,
                progress: progress
            )
        }
        self.healthStartTimeout = healthStartTimeout
        self.healthStopTimeout = healthStopTimeout
        self.healthPollInterval = healthPollInterval
        self.supervision = AutoRestartSupervision(stabilityWindow: stabilityWindow)
        self.now = now
        self.modelStorageURL = config.modelsDirectory.resolvingSymlinksInPath()

        if defaults.object(forKey: Self.ablationEnabledKey) == nil {
            defaults.set(true, forKey: Self.ablationEnabledKey)
        }
        self.ablationEnabled = defaults.bool(forKey: Self.ablationEnabledKey)
        self.ablationStrength = AblationStrength(
            rawValue: defaults.string(forKey: Self.ablationStrengthKey) ?? ""
        ) ?? .defaultValue
        self.bindMode = ServerBindMode(
            rawValue: defaults.string(forKey: Self.bindModeKey) ?? ""
        ) ?? .loopback
        updateLoginItemStatus()
    }

    var settingsValidationError: String? {
        do { try validatePersistedSettings(); return nil }
        catch { return localizedMessage(for: error) }
    }

    private func validatePersistedSettings() throws {
        try preferences.validatePersistedSettings()
        try PersistedSettings.validateEnum(AblationStrength.self, in: defaults, key: Self.ablationStrengthKey)
        try PersistedSettings.validateEnum(ServerBindMode.self, in: defaults, key: Self.bindModeKey)
        if let value = defaults.object(forKey: "damagedComponents") {
            guard let entries = value as? [String],
                  entries.allSatisfy({ InstallationComponent(rawValue: $0) != nil }) else {
                throw PersistedSettings.invalid("damagedComponents")
            }
        }
    }

    func resetInvalidSettings() {
        guard isPrimaryInstance, !isBusy else { return }
        preferences.resetInvalidSettings()
        do { try PersistedSettings.validateEnum(AblationStrength.self, in: defaults, key: Self.ablationStrengthKey) }
        catch { ablationStrength = .defaultValue; defaults.set(ablationStrength.rawValue, forKey: Self.ablationStrengthKey) }
        do { try PersistedSettings.validateEnum(ServerBindMode.self, in: defaults, key: Self.bindModeKey) }
        catch { bindMode = .loopback; defaults.set(bindMode.rawValue, forKey: Self.bindModeKey) }
        if let value = defaults.object(forKey: "damagedComponents"),
           !(value is [String]) || (value as? [String])?.allSatisfy({ InstallationComponent(rawValue: $0) != nil }) == false {
            // Lost verification state requires verification of every component again.
            damagedComponents = Set(InstallationComponent.allCases)
        }
        refreshInstallationStatus()
    }

    // MARK: - Derived state

    var canStart: Bool {
        installationStatus == .ready
            && settingsValidationError == nil
            && installationTask == nil
            && !isBusy
            && status == .stopped
            && isPrimaryInstance
    }

    var canStop: Bool {
        !isBusy && (status == .running || status == .starting) && isPrimaryInstance
    }

    var canRestart: Bool {
        !isBusy && status == .running && isPrimaryInstance && settingsValidationError == nil
    }

    /// True while a healthy server exists that this launcher does not manage but
    /// can still stop.
    var canStopUnownedServer: Bool {
        unownedServer != nil && !isBusy && isPrimaryInstance
    }

    /// True while ``unownedServer`` can actually be adopted by this launcher.
    ///
    /// A listener identified through the port is not the launcher's binary, so
    /// `discoverRunningServer()` finds nothing for it and
    /// ``adoptUnownedServer()`` returns `false` without any state change. The
    /// view must not offer an affordance that silently does nothing.
    var canAdoptUnownedServer: Bool {
        unownedServer != nil
            && !unownedServerIsForeign
            && !isBusy
            && isPrimaryInstance
    }

    /// Unknown running options must never be replaced by next-launch preferences.
    var effectiveBindMode: ServerBindMode? {
        if status == .running || status == .external || status == .starting { return activeLaunchOptions?.bindMode }
        return bindMode
    }

    var isExposedToLAN: Bool { effectiveBindMode == .allInterfaces }

    /// True when a server is up that this process did not start, so its launch
    /// options were never recorded and ``effectiveBindMode`` is only the
    /// preference's guess.
    ///
    /// Reachable after a relaunch (the PID record and the process survive, the
    /// in-memory options do not) and after a takeover by a second launcher. In
    /// that window a `--no-webui` server can be running while the preference
    /// says loopback, so the view must not advertise the bundled chat page on
    /// the strength of ``effectiveBindMode`` alone.
    var runningServerOptionsAreUnknown: Bool {
        status == .running && activeLaunchOptions == nil
    }

    /// True when the bundled chat page cannot be advertised at all.
    ///
    /// Covers both the server this process adopted without recording its launch
    /// options (``runningServerOptionsAreUnknown``) and a listener it could not
    /// even identify as its own: in neither case did this process launch the
    /// server, so nothing is known about `--no-webui`, and the preference is
    /// only a guess.
    ///
    /// `canOpenChat` stays the correct answer to "would the *recorded* options
    /// serve a chat page"; this is the separate question of whether those
    /// options describe the process that is actually answering.
    var chatAffordanceIsUnreliable: Bool {
        runningServerOptionsAreUnknown || status == .external
    }

    /// False when the running server has no launcher-provided chat UI to open:
    /// in ``ServerBindMode/allInterfaces`` mode the server is started with
    /// `--no-webui`.
    ///
    /// Derived from what the running process was actually launched with, not
    /// from the preference, so a failed restart cannot advertise a chat page the
    /// live server refuses to serve.
    var canOpenChat: Bool {
        effectiveBindMode == .loopback
    }

    /// True while a LAN binding change is waiting for explicit confirmation.
    var isBindModeChangePending: Bool {
        pendingBindMode != nil
    }

    var isPrimaryInstance: Bool {
        !requiresInstanceLock || (instanceLockState == .soleInstance && instanceLock?.pathStillRefersToHeldFile == true)
    }

    /// The owning PID of the other launcher instance, when there is one.
    var otherInstanceOwnerPID: pid_t? {
        if case let .alreadyRunning(ownerPID) = instanceLockState {
            return ownerPID
        }
        return nil
    }

    /// True while the launcher will restart the server by itself after an
    /// abnormal exit.
    var isAutoRestartWanted: Bool {
        supervision.isWanted
    }

    /// Consecutive failed start attempts; supervision pauses at
    /// ``AutoRestartSupervision/maximumConsecutiveFailures``.
    ///
    /// This is the *start-attempt* budget, not a crash count. A server that
    /// crashes shortly after every `/health` resets it on each cycle, so it must
    /// not be presented as the whole story while ``supervisionPauseReason`` is
    /// non-nil.
    var consecutiveStartFailures: Int {
        supervision.consecutiveFailures
    }

    /// Why supervision gave up, or `nil` while it is still retrying.
    ///
    /// The view must prefer this over ``consecutiveStartFailures`` whenever it
    /// is non-nil: a slow crash loop pauses with a single counted failure, so a
    /// notice built from the counter alone reports one failure and says nothing
    /// about the crashes that caused it.
    var supervisionPauseReason: SupervisionPauseReason? {
        supervision.pauseReason
    }

    /// Crashes still inside ``AutoRestartSupervision/crashRateWindow``.
    ///
    /// Exposed separately from ``supervisionPauseReason`` so the notice can
    /// report the crash evidence even in the reason that does not carry it: the
    /// failures-exhausted pause is `.repeatedStartFailures(count:)`, which holds
    /// no crash count, so ``StudioHeroCockpit`` feeds this into
    /// ``StudioPresentation/supervisionNotice(consecutiveFailures:isAutoRestartWanted:pauseReason:crashesInCrashWindow:)``
    /// rather than letting the crash history disappear from the message.
    var crashesInCrashWindow: Int {
        supervision.recentCrashes.count
    }

    /// True while this process is running the artifact download.
    ///
    /// ``hasResumableDownload`` deliberately reads `false` in this state: the
    /// downloader rewrites the resume marker once a second *during* a healthy
    /// transfer, so a marker on disk means "a transfer is running here", not
    /// "a previous transfer can be continued".
    var isDownloadInProgress: Bool {
        installationTask != nil
    }

    /// True while ``presentedError`` holds an unacknowledged message.
    var hasPresentedError: Bool {
        presentedError != nil
    }

    // MARK: - Hardware preflight

    var hardwareAssessment: HardwareAssessment {
        hardwareRequirements.assessment
    }

    /// `false` only when installation must be refused outright (non-arm64 or
    /// less than 16 GiB).
    var canInstallModel: Bool {
        hardwareRequirements.canInstall
    }

    /// Actionable, localized preflight problem — a hard blocker when
    /// ``canInstallModel`` is false, otherwise a warning to show before a
    /// multi-hour download.
    var hardwareIssueMessage: String? {
        hardwareAssessment.issue.map { $0.localizedDescription(using: preferences) }
    }

    // MARK: - Single instance

    /// Takes the process-wide lock. Called once, at app start, and held for the
    /// process lifetime so a second launcher cannot adopt or stop the server
    /// owned by the first.
    func acquireSingleInstanceLock() {
        requiresInstanceLock = true
        guard instanceLock == nil, instanceLockState == .notAcquired else { return }

        do {
            let url = SingleInstanceLock.defaultURL(
                supportDirectory: config.supportDirectory
            )
            let lock = SingleInstanceLock(url: url)
            instanceLock = lock
            switch try lock.acquire() {
            case .acquired:
                instanceLockState = .soleInstance
            case let .alreadyRunning(ownerPID):
                instanceLockState = .alreadyRunning(ownerPID: ownerPID)
            }

            // The kernel drops the `flock` when the process dies, so this is a
            // tidy-up for the normal quit path rather than a correctness need.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseSingleInstanceLock()
                }
            }
        } catch {
            instanceLockState = .unavailable
            present(error)
        }
    }

    func releaseSingleInstanceLock() {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        instanceLock?.release()
        instanceLock = nil
        instanceLockState = .notAcquired
    }

    /// Re-evaluates the process-wide instance lock.
    ///
    /// Called from the monitoring loop, because "who is primary" is not decided
    /// once at launch:
    ///
    /// * a *second* launcher must be able to take over after the first one
    ///   quits — otherwise its controls stay inert for its whole lifetime;
    /// * a *primary* whose lock file was deleted or replaced under it (a cleanup
    ///   utility, a user tidying the support directory) no longer holds the
    ///   inode a new instance would contend for, so it re-acquires the current
    ///   file — and finds out if somebody else got there first.
    func recheckSingleInstanceLock() {
        guard let instanceLock else { return }

        if instanceLock.isHeld {
            guard !instanceLock.pathStillRefersToHeldFile else { return }
            // Our flock no longer guards the path, so it proves nothing; drop it
            // and content for the file that is actually there now.
            instanceLock.release()
        }

        do {
            switch try instanceLock.acquire() {
            case .acquired:
                guard instanceLockState != .soleInstance else { return }
                instanceLockState = .soleInstance
                didBecomePrimaryInstance()
            case let .alreadyRunning(ownerPID):
                instanceLockState = .alreadyRunning(ownerPID: ownerPID)
            }
        } catch {
            instanceLockState = .unavailable
            present(error)
        }
    }

    /// A launcher that has just won the instance lock takes over the job the
    /// previous owner was doing: the persisted run intent is the user's standing
    /// "keep the model running" instruction, so supervision is re-armed instead
    /// of leaving the server down.
    ///
    /// The login item is deliberately *not* consulted here. On a fresh launch
    /// ``monitorSetup()`` treats an enabled login item as standing intent, but a
    /// takeover is not a fresh launch: it happens inside the running app, and
    /// the on-disk intent records the user's most recent explicit action. If the
    /// user pressed Stop moments ago while the login item happens to be on,
    /// manufacturing intent from that login item would silently resurrect a
    /// server the user just stopped — without even a relaunch to explain it.
    /// The intent is authoritative; a crash (which leaves the intent on) is
    /// still recovered.
    private func didBecomePrimaryInstance() {
        // The previous owner may have died mid-migration; its recorded intent
        // belongs to whichever instance is primary now.
        reconcileInterruptedModelMigration()

        if shouldRunIntent {
            supervision.intendToRun()
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // A second instance monitors too: it must notice when the first one
        // exits so it can take over. Its periodic ticks stay read-only and are
        // gated on ``isPrimaryInstance`` — only the lock re-check runs for a
        // secondary, so it neither starts, adopts nor stops anything, and it
        // does not re-probe `/health` or `/metrics` every two seconds.
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            await self?.monitorSetup()
            while !Task.isCancelled {
                if self == nil { break }
                await self?.monitorTick1()
                try? await Task.sleep(for: .seconds(2))
                if self == nil { break }
                await self?.monitorTick2()
            }
            self?.isMonitoring = false
        }
    }

    /// Internal rather than private so the test suite can drive one supervision
    /// cycle deterministically instead of sleeping on the 2-second timer.
    ///
    /// Runs a single status snapshot for every instance — a second launcher's
    /// window still has to show whether the server is up — but the intent and
    /// the token poll are primary-only.
    func monitorSetup() async {
        guard !isMonitoring else { return }
        isMonitoring = true

        await refreshModelStorage()
        refreshInstallationStatus()
        if installationStatus == .ready {
            await refresh()
        } else {
            status = .stopped
        }

        // Only the primary instance may touch the persisted run intent: a second
        // launcher must never resurrect a server the first one's user stopped.
        guard isPrimaryInstance else { return }

        // A model migration that was interrupted by a quit or a crash left its
        // pre-stop intent behind, while `stop()` had already written the run
        // intent off. Put it back before the auto-start decision reads it.
        reconcileInterruptedModelMigration()

        // The login item is the user's standing "keep the model running"
        // intent, so it must not depend on the installation being visible at
        // this instant: after a reboot an external volume mounts seconds after
        // login, so the model only becomes `.ready` later. Gating the intent on
        // a status snapshot here killed the headline auto-start feature until
        // the user clicked Start once.
        if autoStartEnabled {
            shouldRunIntent = true
        }
        if shouldRunIntent {
            supervision.intendToRun()
        }
    }

    /// Restores the run intent that ``performModelMigration(to:)`` recorded
    /// before it stopped the service.
    ///
    /// `stop()` writes the run intent off — that is how "the user pressed Stop"
    /// is persisted — but pausing for a model copy is not the user asking to
    /// stop. The record is written *before* the stop and cleared once the intent
    /// has been restored, so a quit or a crash in between leaves it behind for
    /// this method to find on the next launch.
    private func reconcileInterruptedModelMigration() {
        guard defaults.object(forKey: Self.interruptedMigrationIntentKey) != nil else {
            return
        }
        let intentBeforeMigration = defaults.bool(forKey: Self.interruptedMigrationIntentKey)
        defaults.removeObject(forKey: Self.interruptedMigrationIntentKey)

        guard intentBeforeMigration else { return }
        shouldRunIntent = true
    }

    /// Internal for the same reason as ``monitorSetup()``.
    func monitorTick1() async {
        // A second instance must not probe the model location or start anything;
        // its only job is the lock re-check in ``monitorTick2()``.
        guard isPrimaryInstance else { return }

        await refreshModelLocationAvailability()
        guard installationStatus == .ready,
              installationTask == nil,
              !isBusy,
              status == .stopped
        else {
            return
        }
        guard supervision.canAttemptStart(at: now()) else { return }
        await start(userInitiated: false)
    }

    /// Internal for the same reason as ``monitorSetup()``.
    func monitorTick2() async {
        // Who is primary is re-decided on every cycle rather than once at
        // launch: a *second* launcher must be able to take over after the first
        // one exits, and a lock file deleted under the owner must not silently
        // produce two primaries.
        recheckSingleInstanceLock()

        // The lock re-check is the whole periodic job of a secondary: the
        // status snapshot it shows comes from the one ``monitorSetup()`` pass.
        // Refreshing here instead made a secondary re-probe `/health` and
        // `/metrics` every ~2 s for as long as it stayed open.
        guard isPrimaryInstance else { return }

        if installationStatus == .ready, !isBusy {
            await refresh()
        }
    }

    // MARK: - Installation

    func beginInstallation(prepareModel: Bool = false) {
        guard installationTask == nil,
              settingsValidationError == nil,
              isPrimaryInstance,
              status == .stopped || status == .checking,
              installationStatus == .required || installationStatus == .failed
        else {
            return
        }

        refreshInstallationStatus()
        guard !missingArtifacts.isEmpty else { return }

        // Refuse to download ~8 GB onto a Mac that cannot run the bundled
        // arm64 runtime or lacks the memory for the 27B model.
        guard hardwareRequirements.canInstall else {
            installationError = hardwareIssueMessage
                ?? preferences.localized("这台 Mac 不满足运行 Bonsai 2 的最低要求。")
            installationStatus = .failed
            return
        }

        prepareAfterInstallation = prepareModel
        isPreparingQuickStart = prepareModel
        let artifacts = missingArtifacts
        repairingComponents = Set(artifacts.map(\.component))
        installationStatus = .installing
        installationProgress = nil
        installationError = nil
        isCancellingInstallation = false
        // The transfer this call starts is not something the user can "continue":
        // the marker on disk is about to be rewritten every second by the
        // downloader, so publishing it as a resumable download was misleading.
        hasResumableDownload = false

        installationTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard !(await processManager.isRunning()), isPrimaryInstance else { throw ServerProcessError.portStillResponding }
                var required: [InstallationArtifact] = []
                for artifact in artifacts {
                    if damagedComponents.contains(artifact.component),
                       (try await installationInspector.verify(artifact, config: config)) == .verified { continue }
                    required.append(artifact)
                }
                try await installationRunner(required) { [weak self] progress in
                    await self?.receiveInstallationProgress(progress)
                }
                await finishInstallation()
            } catch {
                if Self.isInstallationCancellation(error) {
                    finishInstallationCancellation()
                } else {
                    finishInstallationFailure(error)
                }
            }
        }
    }

    nonisolated static func isInstallationCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    nonisolated static func canMigrateAfterStopping(_ status: ServiceStatus) -> Bool {
        status == .stopped
    }

    func cancelInstallation() {
        prepareAfterInstallation = false
        guard installationTask != nil else { return }
        isCancellingInstallation = true
        installationTask?.cancel()
    }

    private var damagedComponents: Set<InstallationComponent> {
        get { Set((defaults.stringArray(forKey: "damagedComponents") ?? []).compactMap(InstallationComponent.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue), forKey: "damagedComponents") }
    }
    var hasDamagedComponents: Bool { !damagedComponents.isEmpty }
    private var repairingComponents: Set<InstallationComponent> = []

    func recordVerification(_ results: [InstallationComponent: ArtifactVerification]) {
        guard isPrimaryInstance else { return }
        var damaged = damagedComponents
        for (component, result) in results {
            if result.needsRepair { damaged.insert(component) } else { damaged.remove(component) }
        }
        damagedComponents = damaged
        recheckInstallation()
    }

    func repairDamagedArtifacts() async {
        guard isPrimaryInstance, !isBusy, installationTask == nil, !damagedComponents.isEmpty else { return }
        await refresh()
        if status == .running || status == .starting { await stop() }
        guard status == .stopped, !(await processManager.isRunning()) else { return }
        beginInstallation()
    }

    func copyAPIKey() {
        guard isPrimaryInstance, !runningServerOptionsAreUnknown, status != .external else { return }
        do {
            let key = try ApiKeyStore.applicationDefault(supportDirectory: config.supportDirectory).loadOrCreateKey()
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            clipboard.setString(key, forType: .string)
            let revision = clipboard.changeCount
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if clipboard.changeCount == revision { clipboard.clearContents() }
            }
        } catch { present(error) }
    }

    func rotateAPIKey() async {
        guard isPrimaryInstance, !isBusy, status != .external, !runningServerOptionsAreUnknown else { return }
        let wasRunning = status == .running
        if wasRunning { await stop() }
        guard status == .stopped, !(await processManager.isRunning()) else { return }
        do {
            try ApiKeyStore.applicationDefault(supportDirectory: config.supportDirectory).rotateKey()
            if wasRunning { await start() }
        } catch { present(error) }
    }

    func recheckInstallation() {
        guard installationTask == nil else { return }
        installationStatus = .checking
        installationError = nil
        installationProgress = nil
        refreshInstallationStatus()
    }

    func recheckInstallationIncludingModelStorage() async {
        await refreshModelStorage()
        recheckInstallation()
    }

    // MARK: - Service lifecycle

    /// Starts the server.
    ///
    /// `userInitiated` distinguishes an explicit user Start (which also resets
    /// the auto-restart failure budget) from a supervision retry, so a retry
    /// loop cannot reset its own budget and spin forever.
    func start(userInitiated: Bool = true, presentErrors: Bool = true) async {
        guard canStart else { return }
        latestError = nil
        chatOpenError = nil
        shouldRunIntent = true
        if userInitiated {
            supervision.intendToRun()
        } else {
            supervision.noteWanted()
        }
        tokenUsage = nil
        isBusy = true
        currentOperation = .starting
        status = .starting

        do {
            try await processManager.start(options: launchOptions)
            guard await waitForHealth(
                expectedHealthy: true,
                timeout: healthStartTimeout
            ) else {
                let exitedBeforeReady = await !processManager.isRunning()
                try? await processManager.stop()
                throw exitedBeforeReady ? ServerProcessError.exitedBeforeReady : .healthCheckTimedOut
            }
            // Passing `/health` once is *not* recorded as a success: a server
            // that dies seconds later (OOM on the first long-context request)
            // must keep spending the failure budget, otherwise supervision
            // reloads several GB forever. `refresh()` opens the stability window.
            //
            // It *is* recorded as a healthy observation, though. Opening the
            // window here — rather than only from `refresh()` — is what makes a
            // death in the gap between this check and the `refresh()` below
            // countable: `refresh()` records a failure only when
            // `healthySince != nil`, so without this a load-then-die crash
            // before the first sighting was counted by nothing at all and
            // supervision restarted with zero backoff, forever.
            supervision.noteHealthy(at: now())
            activeLaunchOptions = launchOptions
        } catch {
            // A transient failure must not be mistaken for the user's intent:
            // only Stop clears the run intent, so recovery survives restarts.
            if !Task.isCancelled, !Self.isInstallationCancellation(error) {
                supervision.recordFailure(at: now())
                if presentErrors { present(error) }
                else { latestError = localizedMessage(for: error) }
            }
        }
        currentOperation = nil
        isBusy = false
        await refresh()
    }

    func stop() async {
        guard canStop else { return }
        shouldRunIntent = false
        supervision.clearIntent()
        isBusy = true
        currentOperation = .stopping
        status = .stopping

        do {
            try await processManager.stop()
            // Only once the stop was accepted: a failed stop leaves the server
            // running with the options it was launched with.
            activeLaunchOptions = nil
                _ = await waitForHealth(
                expectedHealthy: false,
                timeout: healthStopTimeout
            )
        } catch {
            presentUnlessCancelled(error)
        }
        currentOperation = nil
        isBusy = false
        await refresh()
    }

    func restart() async {
        guard canRestart else { return }
        shouldRunIntent = true
        supervision.intendToRun()
        tokenUsage = nil
        isBusy = true
        currentOperation = .restarting
        status = .restarting

        do {
            try await processManager.stop()
            guard await waitForHealth(
                expectedHealthy: false,
                timeout: healthStopTimeout
            ) else {
                throw ServerProcessError.portStillResponding
            }
            try await processManager.start(options: launchOptions)
            guard await waitForHealth(
                expectedHealthy: true,
                timeout: healthStartTimeout
            ) else {
                let exitedBeforeReady = await !processManager.isRunning()
                try? await processManager.stop()
                throw exitedBeforeReady ? ServerProcessError.exitedBeforeReady : .healthCheckTimedOut
            }
            // Same reasoning as ``start(userInitiated:)``: opening the window on
            // a successful `/health` is what makes a death before the next
            // observation count against the budget.
            supervision.noteHealthy(at: now())
            activeLaunchOptions = launchOptions
        } catch {
            if !Task.isCancelled, !Self.isInstallationCancellation(error) {
                supervision.recordFailure(at: now())
                present(error)
            }
        }
        currentOperation = nil
        isBusy = false
        await refresh()
    }

    /// Stops a healthy server the launcher could not adopt, so the user never
    /// has to reach for Activity Monitor.
    func stopUnownedServer() async {
        guard canStopUnownedServer, let target = unownedServer else { return }
        isBusy = true
        do {
            if unownedServerIsForeign {
                // Not the launcher's binary: it can only be stopped, and only
                // after the listener identity is re-verified at signal time.
                try await processManager.stopPortListener(target)
            } else {
                try await processManager.stopDiscoveredServer()
            }
            unownedServer = nil
            unownedServerIsForeign = false
        } catch {
            presentUnlessCancelled(error)
        }
        isBusy = false
        await refresh()
    }

    /// Retries adoption of ``unownedServer``; returns true once it is managed.
    @discardableResult
    func adoptUnownedServer() async -> Bool {
        guard unownedServer != nil else { return false }
        let adopted = await adoptUnownedServerIfPossible()
        await refresh()
        return adopted
    }

    // MARK: - Settings

    func setAblationEnabled(_ enabled: Bool) async {
        guard enabled != ablationEnabled, !isBusy, isPrimaryInstance else { return }

        ablationEnabled = enabled
        defaults.set(enabled, forKey: Self.ablationEnabledKey)

        if status == .running {
            await restart()
        }
    }

    func setAblationStrength(_ strength: AblationStrength) async {
        guard strength != ablationStrength, !isBusy, isPrimaryInstance else { return }

        ablationStrength = strength
        defaults.set(strength.rawValue, forKey: Self.ablationStrengthKey)

        if ablationEnabled && status == .running {
            await restart()
        }
    }

    /// Applies a bind-mode change.
    ///
    /// Switching *to* ``ServerBindMode/allInterfaces`` publishes an
    /// API-key-protected service on the local network and disables the bundled
    /// WebUI, so it is only applied when `confirmed` is true; otherwise the
    /// request is parked in ``pendingBindMode`` for the view to confirm.
    /// Switching back to loopback is always safe and applies immediately.
    func setBindMode(_ mode: ServerBindMode, confirmed: Bool = false) async {
        guard mode != bindMode, !isBusy, isPrimaryInstance else { return }

        if mode == .allInterfaces, !confirmed {
            pendingBindMode = mode
            return
        }

        pendingBindMode = nil
        bindMode = mode
        defaults.set(mode.rawValue, forKey: Self.bindModeKey)

        if status == .running {
            await restart()
        }
    }

    /// The dialog supplies its captured choice because dismissal clears pending state.
    func confirmBindMode(_ mode: ServerBindMode) async {
        await setBindMode(mode, confirmed: true)
    }

    func cancelPendingBindMode() {
        pendingBindMode = nil
    }

    func setAutoStart(_ enabled: Bool) async {
        guard enabled != autoStartEnabled, isPrimaryInstance else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            updateLoginItemStatus()

            if enabled && status == .stopped {
                await start()
            }
        } catch {
            updateLoginItemStatus()
            present(error)
        }
    }

    @discardableResult
    func openChat() -> Bool {
        guard status == .running, canOpenChat, !chatAffordanceIsUnreliable, !isBusy else { return false }
        let opened = openChatURL(config.chatURL)
        chatOpenError = opened ? nil : preferences.localized("未能打开聊天页面。请重试，或复制本机地址到浏览器。")
        return opened
    }

    func refreshConnectionModelID() async {
        connectionModelID = nil
        connectionModelIDFailed = false
        guard status == .running, canOpenChat, !chatAffordanceIsUnreliable else { return }
        do {
            let id = try await modelIdentifierLoader(config.chatURL)
            guard !Task.isCancelled, status == .running, canOpenChat, !chatAffordanceIsUnreliable else { return }
            connectionModelID = id
        } catch {
            guard !Task.isCancelled else { return }
            connectionModelIDFailed = true
        }
    }

    var quickStartRoute: QuickStartRoute {
        QuickStartRoute.resolve(installation: installationStatus, presented: quickStartPresented,
                                deferred: preferences.setupDeferred, completed: preferences.onboardingCompleted)
    }

    func showQuickStart() {
        quickStartPresented = true
        preferences.setupDeferred = false
    }

    func dismissQuickStart() {
        guard !isDownloadInProgress, !isBusy, !isPreparingQuickStart else { return }
        preferences.setupDeferred = installationStatus != .ready
        if installationStatus == .ready { preferences.onboardingCompleted = true }
        quickStartPresented = false
    }

    var hardwareSummary: String {
        "\(hardwareRequirements.architecture) · \(hardwareRequirements.physicalMemoryBytes.formatted(.byteCount(style: .memory)))"
    }

    var canBeginGuidedInstallation: Bool {
        canInstallModel && isPrimaryInstance && !isBusy && !isDownloadInProgress
            && settingsValidationError == nil && !modelStorageConfigurationUnavailable
            && (status == .stopped || status == .checking || (hasDamagedComponents && status == .running))
            && !missingArtifacts.isEmpty && installationSpaceError == nil
            && installationSpace?.allSatisfy(\.isSufficient) == true
    }

    func refreshInstallationSpace() async {
        spaceCheckGeneration += 1
        let generation = spaceCheckGeneration
        let artifacts = missingArtifacts
        installationSpace = nil
        installationSpaceError = nil
        guard !artifacts.isEmpty, !isDownloadInProgress else { return }
        do {
            let report = try await spaceReporter(artifacts)
            guard generation == spaceCheckGeneration, artifacts == missingArtifacts, !Task.isCancelled else { return }
            installationSpace = report
        } catch {
            guard generation == spaceCheckGeneration, !Task.isCancelled else { return }
            installationSpaceError = localizedMessage(for: error)
        }
    }

    func beginGuidedInstallation() async {
        guard !isDownloadInProgress, !isBusy, isPrimaryInstance else { return }
        // Refresh immediately before acting: the displayed free space can go stale.
        await refreshInstallationSpace()
        guard canBeginGuidedInstallation else { return }
        showQuickStart()
        if hasDamagedComponents {
            // Existing repair retains its stop-before-replace safety checks.
            await repairDamagedArtifacts()
            if isDownloadInProgress { prepareAfterInstallation = true; isPreparingQuickStart = true }
        } else {
            beginInstallation(prepareModel: true)
        }
    }

    func prepareModelForQuickStart() async {
        guard canStart else { return }
        isPreparingQuickStart = true
        defer { isPreparingQuickStart = false }
        await start(presentErrors: false)
        // A failed first attempt stays actionable instead of repeatedly consuming
        // memory while a newcomer is trying to read the error.
        if status == .stopped {
            shouldRunIntent = false
            supervision.clearIntent()
        }
    }

    func revealLogs() {
        do {
            try fileManager.createDirectory(
                at: config.logDirectory,
                withIntermediateDirectories: true
            )
            guard openDirectory(config.logDirectory) else {
                presentMessage(preferences.localized("无法在 Finder 中打开日志目录"))
                return
            }
        } catch {
            present(error)
        }
    }

    func revealModels() {
        guard modelStorageIsAvailable else {
            presentMessage(preferences.localized("模型存储位置当前不可用"))
            return
        }
        guard openDirectory(modelStorageURL) else {
            presentMessage(preferences.localized("无法在 Finder 中打开模型目录"))
            return
        }
    }

    var retainedSourceModelMessage: String? {
        guard let retainedSourceModelLocation else { return nil }
        return preferences.localizedFormat(
            "模型已迁移；旧位置 %@ 未能删除，仍占用 %@",
            retainedSourceModelLocation.path(percentEncoded: false),
            retainedSourceModelBytes.formatted(.byteCount(style: .file))
        )
    }

    // MARK: - Model storage

    func refreshModelStorage() async {
        do {
            if isPrimaryInstance { try await modelStorageManager.recoverInterruptedCopy() }
            let snapshot = try await modelStorageManager.snapshot()
            modelStorageURL = snapshot.url
            modelStorageBytes = snapshot.byteCount
            modelStorageIsAvailable = snapshot.isAvailable
            modelStorageConfigurationUnavailable = snapshot.isRelocated && !snapshot.isAvailable
            setModelStorageNotice(snapshot.notice)
            if let source = try config.retainedModelSource {
                retainedSourceModelLocation = source
                if case let .sourceLocationRetained(bytes) = snapshot.notice { retainedSourceModelBytes = bytes }
            }
            reconcileRetainedSourceLocation()
        } catch {
            modelStorageIsAvailable = false
            modelStorageConfigurationUnavailable = true
            present(error)
        }
    }

    private func setModelStorageNotice(_ notice: ModelStorageMigrationNotice?) {
        guard modelStorageNotice != notice else { return }
        modelStorageNotice = notice
    }

    private func refreshModelLocationAvailability() async {
        do {
            let location = try await modelStorageManager.locationStatus()
            let availabilityChanged = modelStorageIsAvailable != location.isAvailable
                || modelStorageConfigurationUnavailable != (location.isRelocated && !location.isAvailable)
                || modelStorageURL != location.url
            guard availabilityChanged else { return }

            modelStorageURL = location.url
            modelStorageIsAvailable = location.isAvailable
            modelStorageConfigurationUnavailable = location.isRelocated && !location.isAvailable
            if location.isAvailable {
                let snapshot = try await modelStorageManager.snapshot()
                modelStorageBytes = snapshot.byteCount
                setModelStorageNotice(snapshot.notice)
            } else {
                modelStorageBytes = 0
                setModelStorageNotice(nil)
            }
            reconcileRetainedSourceLocation()
            refreshInstallationStatus()
        } catch {
            modelStorageIsAvailable = false
            modelStorageConfigurationUnavailable = true
            present(error)
        }
    }

    private func reconcileRetainedSourceLocation() {
        guard let source = retainedSourceModelLocation else { return }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let currentPath = modelStorageURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath == currentPath || !fileManager.fileExists(atPath: source.path) else {
            return
        }
        clearRetainedSourceLocation()
    }

    private func rememberRetainedSourceLocation(_ url: URL, byteCount: Int64) {
        retainedSourceModelLocation = url
        retainedSourceModelBytes = byteCount
    }

    private func clearRetainedSourceLocation() {
        retainedSourceModelLocation = nil
        retainedSourceModelBytes = 0
    }

    func beginModelMigration(to selectedParent: URL) {
        guard modelMigrationTask == nil, isPrimaryInstance else { return }
        modelMigrationTask = Task { [weak self] in
            await self?.performModelMigration(to: selectedParent)
        }
    }

    func cancelModelMigration() {
        guard modelMigrationTask != nil else { return }
        isCancellingModelMigration = true
        modelMigrationTask?.cancel()
    }

    private func performModelMigration(to selectedParent: URL) async {
        guard !isBusy,
              !isModelMigrationInProgress,
              installationStatus == .ready,
              status != .external,
              isPrimaryInstance
        else {
            presentMessage(preferences.localized("请先停止外部模型服务并确认安装完整"))
            modelMigrationTask = nil
            return
        }

        let shouldRestart = status == .running || status == .starting
        // Pausing the service to copy the models is not the user asking to stop
        // it, so remember the intent across the internal `stop()` — and persist
        // it *before* that stop writes the run intent off, because a quit or a
        // crash during the copy would otherwise leave the next launch convinced
        // the user had pressed Stop. `reconcileInterruptedModelMigration()`
        // puts it back.
        let preservedIntent = shouldRunIntent
        if shouldRestart {
            defaults.set(preservedIntent, forKey: Self.interruptedMigrationIntentKey)
            await stop()
            guard Self.canMigrateAfterStopping(status) else {
                shouldRunIntent = true
                supervision.intendToRun()
                defaults.removeObject(forKey: Self.interruptedMigrationIntentKey)
                presentMessage(preferences.localized("模型服务未能停止，未开始迁移。"))
                modelMigrationTask = nil
                return
            }
        }

        isBusy = true
        isModelMigrationInProgress = true
        isCancellingModelMigration = false
        modelMigrationProgress = nil
        modelMigrationOutcome = nil
        let sourceLocation = config.modelsDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        do {
            let snapshot = try await modelStorageManager.migrate(
                to: selectedParent
            ) { [weak self] progress in
                await self?.receiveModelMigrationProgress(progress)
            }
            modelStorageURL = snapshot.url
            modelStorageBytes = snapshot.byteCount
            modelStorageIsAvailable = snapshot.isAvailable
            modelStorageConfigurationUnavailable = false
            setModelStorageNotice(snapshot.notice)
            if case let .sourceLocationRetained(bytes) = snapshot.notice {
                // The manager committed the retained source in model-location.json.
                rememberRetainedSourceLocation(sourceLocation, byteCount: bytes)
            } else {
                clearRetainedSourceLocation()
            }
            modelMigrationOutcome = .success(
                migrationSuccessMessage(for: snapshot, sourceLocation: sourceLocation)
            )
            refreshInstallationStatus()
        } catch {
            await refreshModelStorage()
            if Self.isInstallationCancellation(error) {
                modelMigrationOutcome = .cancelled(
                    preferences.localized("迁移已取消，原模型位置未改变")
                )
            } else {
                // The Settings scene has no alert host, so a failed migration
                // must render itself through `modelMigrationOutcome` or it is
                // completely silent.
                modelMigrationOutcome = .failure(migrationFailureMessage(for: error))
                present(error)
            }
        }
        modelMigrationProgress = nil
        isCancellingModelMigration = false
        isModelMigrationInProgress = false
        isBusy = false
        modelMigrationTask = nil

        shouldRunIntent = preservedIntent
        // The intent is restored, so the crash-recovery record for this
        // migration is no longer needed.
        defaults.removeObject(forKey: Self.interruptedMigrationIntentKey)
        if preservedIntent {
            // `stop()` cleared supervision while pausing; put it back so a
            // cancelled or failed migration still recovers on the next tick.
            supervision.intendToRun()
        }

        // Never chain into `start()` on a cancelled task: `waitForHealth` would
        // return immediately and surface a bogus health-check error after the
        // user asked to cancel a copy. The restored intent lets supervision
        // bring the service back on the next tick instead.
        if shouldRestart, installationStatus == .ready, !Task.isCancelled {
            await start()
        }
    }

    private func migrationSuccessMessage(
        for snapshot: ModelStorageSnapshot,
        sourceLocation: URL
    ) -> String {
        if case let .sourceLocationRetained(bytes) = snapshot.notice {
            // The path is part of the message: "the old location could not be
            // removed" names nothing the user can act on.
            return preferences.localizedFormat(
                "模型已迁移；旧位置 %@ 未能删除，仍占用 %@",
                sourceLocation.path(percentEncoded: false),
                bytes.formatted(.byteCount(style: .file))
            )
        }
        return preferences.localized("模型已迁移，已更新存储位置")
    }

    private func migrationFailureMessage(for error: Error) -> String {
        if let localizable = error as? any AppLocalizableError {
            return localizable.localizedDescription(using: preferences)
        }
        return preferences.localizedFormat("模型迁移失败：%@", error.localizedDescription)
    }

    private func receiveModelMigrationProgress(_ progress: ModelStorageMigrationProgress) {
        modelMigrationProgress = progress
    }

    // MARK: - Refresh

    private var reportedLogFailure: String?

    func refresh() async {
        if let failure = await processManager.logMaintenanceFailure(), failure != reportedLogFailure {
            reportedLogFailure = failure
            presentMessage(failure)
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration

        async let managed = processManager.isRunning()
        async let healthy = isHealthy()
        let state = await (managed, healthy)
        guard generation == refreshGeneration else { return }

        // Whether the launcher's *own* PID record pointed at the live server
        // before this pass tried to adopt anything. That is what separates "a
        // server this launcher started" (whose options were recorded at launch)
        // from "a server found on the port" (whose options nobody knows).
        let isManagedServer = state.0

        // The port answers but the launcher no longer tracks the process: adopt
        // our own binary so status becomes managed and the controls work again.
        if !state.0, state.1, currentOperation == nil, isPrimaryInstance {
            unownedServer = await processManager.discoverRunningServer()
            unownedServerIsForeign = false
            if unownedServer == nil {
                unownedServer = await processManager.portListener()
                unownedServerIsForeign = unownedServer != nil
            }
            guard generation == refreshGeneration else { return }
        } else if state.0 {
            unownedServer = nil
            unownedServerIsForeign = false
        } else {
            // Nothing of ours is running and nothing answers on the port, so the
            // listener this launcher published cannot still be there. Without
            // this branch a foreign listener that exited stayed published: the
            // cockpit showed the stopped status next to a healthy-service card
            // naming a dead PID, with an enabled stop button that no-opped
            // forever, because neither of the branches above ran.
            unownedServer = nil
            unownedServerIsForeign = false
        }

        status = ServiceStatus.resolve(
            isLoaded: state.0,
            isHealthy: state.1,
            operation: currentOperation
        )

        activeLaunchOptions = isManagedServer ? await processManager.runningLaunchOptions() : nil
        guard generation == refreshGeneration else { return }
        updateSupervision(isHealthy: status == .running, isStopped: status == .stopped)

        // Token usage describes the managed process, and only the primary
        // manages it: a secondary launcher shows no telemetry rather than
        // polling `/metrics` every cycle alongside the owner.
        if state.0, state.1, isPrimaryInstance, activeLaunchOptions?.bindMode == .loopback {
            await refreshTokenUsage(generation: generation)
        } else {
            tokenUsage = nil
        }

        updateLoginItemStatus()
    }

    /// Feeds one observation of the managed service into supervision.
    ///
    /// A server that was healthy and is now gone did not "succeed" — it crashed
    /// after passing `/health` (OOM/Jetsam on the first long-context request is
    /// the realistic shape). Counting it as a failure is what gives the crash
    /// loop a growing backoff and, eventually, a visible pause instead of an
    /// endless multi-gigabyte reload.
    private func updateSupervision(isHealthy: Bool, isStopped: Bool) {
        guard supervision.isWanted else { return }

        if isHealthy {
            supervision.noteHealthy(at: now())
        } else if isStopped, supervision.healthySince != nil {
            supervision.recordCrash(at: now())
        }
    }

    /// Re-attaches the launcher to a healthy server it stopped tracking, and
    /// publishes it as ``unownedServer`` when adoption is not possible.
    @discardableResult
    private func adoptUnownedServerIfPossible() async -> Bool {
        if let discovered = await processManager.discoverRunningServer() {
            if await processManager.adoptDiscoveredServer() != nil {
                unownedServer = nil
                unownedServerIsForeign = false
                return true
            }
            unownedServer = discovered
            unownedServerIsForeign = false
            return false
        }

        // None of our runtime binaries is running, so the healthy port belongs
        // to something else entirely (started by hand from another folder, or by
        // another tool). Identify the listener so the card can still explain the
        // state and offer a stop path instead of a dead end.
        unownedServer = await processManager.portListener()
        unownedServerIsForeign = unownedServer != nil
        return false
    }

    private func updateLoginItemStatus() {
        let loginStatus = loginItemStatus()
        autoStartEnabled = loginStatus == .enabled || loginStatus == .requiresApproval
        loginItemRequiresApproval = loginStatus == .requiresApproval
    }

    /// Internal so the install-in-progress gate can be tested directly.
    func refreshInstallationStatus() {
        // An install is in flight: a transient volume change must not let the
        // supervisor claim the model is ready and start against a
        // half-installed model.
        //
        // `hasResumableDownload` is cleared here rather than left frozen: the
        // downloader rewrites the resume marker once a second *while a healthy
        // transfer runs*, so a non-empty marker now means "a download is running
        // in this process", not "a previous download can be continued". Reporting
        // it as resumable mid-flight made the install card promise to "继续下载"
        // a transfer that is already downloading.
        guard installationTask == nil else {
            hasResumableDownload = false
            return
        }

        do {
            try validatePersistedSettings()
            let configuredURL = try config.configuredModelsDirectory()
            modelStorageConfigurationUnavailable = try config.hasCustomModelLocation && ManagedFileSystem.metadata(at: configuredURL) == nil
            if modelStorageConfigurationUnavailable {
                missingArtifacts = []
                reusedArtifacts = []
                hasResumableDownload = false
                installationError = preferences.localized(
                    "已配置的模型位置不可用。请恢复该文件夹后重新检测。"
                )
                installationStatus = .failed
                return
            }

            let artifacts = installationCatalog.artifacts(for: config)
            missingArtifacts = try artifacts.filter {
                try damagedComponents.contains($0.component) || !installationInspector.isInstalled($0, config: config)
            }
            let missingComponents = Set(missingArtifacts.map(\.component))
            reusedArtifacts = artifacts.filter { !missingComponents.contains($0.component) }
            hasResumableDownload = try missingArtifacts.contains { artifact in
                try DownloadProgressCheckpoint().read(from: config.resumeDataURL(for: artifact.component)) > 0
            }
            installationStatus = missingArtifacts.isEmpty ? .ready : .required
        } catch {
            missingArtifacts = []
            reusedArtifacts = []
            hasResumableDownload = false
            installationError = localizedMessage(for: error)
            installationStatus = .failed
        }
    }

    private func receiveInstallationProgress(_ progress: InstallationProgress) {
        installationProgress = progress
    }

    private func finishInstallation() async {
        defer { isPreparingQuickStart = false }
        let shouldPrepare = prepareAfterInstallation
        prepareAfterInstallation = false
        damagedComponents.subtract(repairingComponents)
        repairingComponents = []
        installationTask = nil
        installationProgress = nil
        installationError = nil
        isCancellingInstallation = false
        refreshInstallationStatus()

        if installationStatus == .ready {
            status = .stopped
            await refresh()
            if shouldPrepare, !Task.isCancelled { await prepareModelForQuickStart() }
        }
    }

    private func finishInstallationCancellation() {
        isPreparingQuickStart = false
        prepareAfterInstallation = false
        installationTask = nil
        installationProgress = nil
        installationError = nil
        isCancellingInstallation = false
        refreshInstallationStatus()
    }

    private func finishInstallationFailure(_ error: Error) {
        isPreparingQuickStart = false
        prepareAfterInstallation = false
        installationTask = nil
        installationProgress = nil
        isCancellingInstallation = false
        refreshInstallationStatus()
        installationError = localizedMessage(for: error)
        installationStatus = .failed
    }

    // MARK: - Process helpers

    private var launchOptions: ServerLaunchOptions {
        ServerLaunchOptions(
            ablationEnabled: ablationEnabled,
            ablationStrength: ablationStrength,
            bindMode: bindMode
        )
    }

    /// The user's persisted intent that the model server should be running.
    /// Cleared only by an explicit stop.
    private var shouldRunIntent: Bool {
        get { defaults.bool(forKey: Self.shouldRunKey) }
        set { defaults.set(newValue, forKey: Self.shouldRunKey) }
    }

    private static let monitoringSession = LocalMonitorTransport.session()

    static func probeHealth(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 1.5

        do {
            let (_, response) = try await monitoringSession.data(for: request, delegate: LocalMonitorRedirectPolicy())
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func isHealthy() async -> Bool {
        await healthProbe(config.chatURL)
    }

    private func waitForHealth(expectedHealthy: Bool, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline && !Task.isCancelled {
            // A failed loader cannot become healthy after its process exits.
            // Keep the stop path probing: a different process may still own the port.
            if expectedHealthy, await !processManager.isRunning() { return false }
            if await isHealthy() == expectedHealthy {
                return true
            }
            try? await Task.sleep(for: healthPollInterval)
        }
        return false
    }

    private(set) var tokenUsageError: String?

    private func refreshTokenUsage(generation: Int) async {
        do {
            let snapshot = try await metricsClient.fetch(baseURL: config.chatURL)
            guard generation == refreshGeneration, status == .running else { return }
            tokenUsage = snapshot
            tokenUsageError = nil
        } catch {
            guard generation == refreshGeneration, status == .running else { return }
            tokenUsage = nil
            tokenUsageError = localizedMessage(for: error)
            latestError = tokenUsageError
        }
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        presentMessage(localizedMessage(for: error))
    }

    /// Cancellation is the user's own request, never an error to alert about.
    private func presentUnlessCancelled(_ error: Error) {
        guard !Task.isCancelled, !Self.isInstallationCancellation(error) else { return }
        present(error)
    }

    private func presentMessage(_ message: String) {
        latestError = message
        presentedError = message
    }

    func acknowledgePresentedError() {
        presentedError = nil
    }

    /// Internal so the two-tier error mapping can be asserted by the test suite.
    func localizedMessage(for error: Error) -> String {
        if let localizedError = error as? any AppLocalizableError {
            return localizedError.localizedDescription(using: preferences)
        }
        return systemErrorMessage(for: error)
    }

    /// Maps raw Foundation / POSIX / ServiceManagement failures onto the same
    /// two-tier convention as the rest of the app, so no English `NSError` text
    /// reaches a fully-Chinese UI.
    ///
    /// Highest-value case: `SMAppService.mainApp.register()` fails with
    /// `SMAppServiceErrorDomain` code 1 whenever the app is not in
    /// `/Applications`, is quarantined, or runs App-Translocated — the default
    /// state of a build launched straight from `~/Downloads`.
    private func systemErrorMessage(for error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == Self.appServiceErrorDomain {
            return preferences.localized(
                "无法注册开机启动：请将“27B Launcher”拖入“应用程序”文件夹，重新打开后再试。"
            )
        }

        if FileSystemFailure.isOutOfSpace(error) {
            return preferences.localized("磁盘空间不足，操作未完成；请清理磁盘后重试。")
        }
        if FileSystemFailure.isPermissionDenied(error) {
            return preferences.localized("没有访问该位置的权限；请检查文件权限后重试。")
        }
        if FileSystemFailure.isMissingSource(error) {
            return preferences.localized("找不到所需的文件或文件夹；它可能已被移动或删除。")
        }

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError):
            return preferences.localized("目标位置为只读，无法写入。")
        case (NSCocoaErrorDomain, NSFileWriteFileExistsError):
            return preferences.localized("目标位置已存在同名文件。")
        case (NSPOSIXErrorDomain, _):
            return preferences.localizedFormat(
                "系统调用失败（errno %lld），操作未完成。",
                Int64(nsError.code)
            )
        default:
            return preferences.localizedFormat("操作未完成：%@", nsError.localizedDescription)
        }
    }
}
