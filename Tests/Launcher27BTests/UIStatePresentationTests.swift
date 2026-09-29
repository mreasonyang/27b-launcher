import Foundation
import ServiceManagement
import Testing
@testable import Launcher27B

/// Verifies that views present the service and storage state published by
/// `ServiceController`, including foreign listeners, parked models, LAN exposure,
/// and crash-loop pauses.
@Suite
struct UIStatePresentationTests {
    // MARK: - Adoption is only offered when it can succeed

    /// A listener found through the port is not the launcher's binary, so
    /// `discoverRunningServer()` returns nothing for it and adoption returns
    /// `false` without a spinner, an alert or a state change. Both adopt
    /// affordances were nevertheless enabled, and in `.external` the hero button
    /// (`hasUnownedServer` is tested before the status switch) replaced Start /
    /// Open Chat as the most prominent control in the window.
    @Test
    @MainActor
    func aForeignListenerIsNeverOfferedAdoption() async throws {
        let context = try makeContext("uiw-foreign")
        defer { context.cleanUp() }

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

        let controller = context.makeController(
            stub: process,
            healthProbe: { url in await probe.probe(url) }
        )

        await controller.refresh()

        #expect(controller.status == .external)
        #expect(controller.unownedServer == foreign)
        #expect(controller.unownedServerIsForeign)

        // The adopt action is not available at all …
        #expect(!controller.canAdoptUnownedServer)
        // … while the stop path — the one that actually works — still is.
        #expect(controller.canStopUnownedServer)

        // … and it is not what the hero offers. A foreign listener's launch
        // options are unknown, so the working affordance is the API address, not
        // a bundled chat page the stranger may not serve.
        #expect(
            primaryAction(
                for: controller,
                status: controller.status,
                hasUnownedServer: true
            ) != .adoptUnownedServer
        )
        #expect(
            primaryAction(
                for: controller,
                status: controller.status,
                hasUnownedServer: true
            ) == .copyAPIAddress
        )
    }

    /// Verify the adopt path is available when a listener discovered
    /// by executable path is still adoptable, and the hero must keep offering it.
    @Test
    @MainActor
    func anAdoptableListenerStillOffersAdoption() async throws {
        let context = try makeContext("uiw-adoptable")
        defer { context.cleanUp() }

        let process = StubServerProcessManager()
        process.isRunningValue = false
        process.adoptSucceeds = false
        process.discovered = ServerProcessDescriptor(
            pid: 4242,
            executablePath: "/tmp/llama-server",
            isManaged: false
        )

        let controller = context.makeController(
            stub: process,
            healthProbe: { _ in true }
        )
        await controller.refresh()

        #expect(controller.unownedServer?.pid == 4242)
        #expect(!controller.unownedServerIsForeign)
        #expect(controller.canAdoptUnownedServer)
        #expect(
            primaryAction(for: controller, status: controller.status, hasUnownedServer: true)
                == .adoptUnownedServer
        )
    }

    // MARK: - Unknown launch options do not imply a chat page

    /// After a relaunch (or a takeover by a second launcher) the process is still
    /// up but the options it was launched with are gone, so `effectiveBindMode`
    /// falls back to the preference. A `--no-webui` server can be the one
    /// answering while `canOpenChat` is `true` — the hero then opened a dead page.
    @Test
    @MainActor
    func chatIsNotOfferedWhenTheRunningServersOptionsAreUnknown() async throws {
        let context = try makeContext("uiw-unknown-options")
        defer { context.cleanUp() }

        let process = StubServerProcessManager()
        process.isRunningValue = true

        let controller = context.makeController(
            stub: process,
            healthProbe: { _ in true }
        )
        await controller.refresh()

        #expect(controller.status == .running)
        #expect(controller.activeLaunchOptions == nil)
        #expect(controller.runningServerOptionsAreUnknown)
        #expect(controller.chatAffordanceIsUnreliable)
        // The preference still claims loopback, which is exactly why the
        // preference alone must not drive the chat affordance.
        #expect(controller.bindMode == .loopback)
        #expect(!controller.canOpenChat)

        #expect(
            primaryAction(for: controller, status: .running, hasUnownedServer: false)
                == .copyAPIAddress
        )
    }

    // MARK: - LAN warning follows the running server

    /// A bind-mode switch to loopback publishes the preference *before* the
    /// restart. When the restart's stop fails, the old `--no-webui` server keeps
    /// listening on `0.0.0.0` with no authentication while the preference says
    /// loopback — the safety warning disappeared exactly when it was needed.
    @Test
    @MainActor
    func theLanWarningSurvivesAFailedBindModeRestart() async throws {
        let context = try makeContext("uiw-lan-warning")
        defer { context.cleanUp() }
        try makeCompleteInstallation(config: context.config)

        let process = StubServerProcessManager()
        let controller = context.makeController(
            stub: process,
            healthProbe: { _ in process.isRunningValue },
            fastHealth: true
        )

        controller.recheckInstallation()
        await controller.refresh()
        #expect(controller.installationStatus == .ready)

        await controller.setBindMode(.allInterfaces, confirmed: true)
        await controller.start()
        #expect(controller.status == .running)
        #expect(controller.isExposedToLAN)

        // The user switches back to loopback, but the stop fails.
        process.stopError = ServerProcessError.signalFailed(errno: EPERM)
        await controller.setBindMode(.loopback)

        // The preference now says loopback, while the live server is still on 0.0.0.0.
        #expect(controller.bindMode == .loopback)
        #expect(controller.effectiveBindMode == .allInterfaces)
        #expect(controller.isExposedToLAN)
    }

    // MARK: - Report the crash loop

    /// The pause has two causes. A stable server that crashes and is restarted
    /// resets the consecutive-failure budget on every cycle, so the crash-loop
    /// pause arrives with `consecutiveStartFailures == 1`; a notice built from the
    /// counter alone understated it and never mentioned crashing.
    @Test
    @MainActor
    func theCrashLoopPauseRendersACrashLoopSpecificMessage() async throws {
        let context = try makeContext("uiw-crash-loop")
        defer { context.cleanUp() }
        try makeCompleteInstallation(config: context.config)

        let process = StubServerProcessManager()
        let instant = ServiceControllerLifecycleTests.TestInstant()
        let controller = context.makeController(
            stub: process,
            healthProbe: { _ in process.isRunningValue },
            loginItemStatus: { .enabled },
            fastHealth: true,
            now: { instant.value }
        )

        await controller.monitorSetup()
        await controller.monitorTick1()
        #expect(controller.status == .running)

        for cycle in 1...AutoRestartSupervision.maximumCrashesPerWindow {
            // Each run outlives the stability window, so the budget resets.
            instant.advance(by: .seconds(60))
            await controller.monitorTick2()
            process.isRunningValue = false
            await controller.monitorTick2()
            guard cycle < AutoRestartSupervision.maximumCrashesPerWindow else { continue }
            await controller.start(userInitiated: false)
        }

        #expect(!controller.isAutoRestartWanted)
        #expect(controller.consecutiveStartFailures == 1)
        #expect(
            controller.supervisionPauseReason
                == .crashLoop(crashesInWindow: AutoRestartSupervision.maximumCrashesPerWindow)
        )

        let notice = StudioPresentation.supervisionNotice(
            consecutiveFailures: controller.consecutiveStartFailures,
            isAutoRestartWanted: controller.isAutoRestartWanted,
            pauseReason: controller.supervisionPauseReason
        )
        #expect(
            notice == .pausedByCrashLoop(
                crashes: AutoRestartSupervision.maximumCrashesPerWindow,
                failures: 1
            )
        )
        // The reason must select the sentence, and it must not be the
        // failure-count one that says “已连续失败 1 次”.
        #expect(
            notice.messageKey
                == "模型在 %lld 分钟内崩溃 %lld 次，自动重启已暂停；请点击“启动模型”手动重试，并查看日志排查原因。"
        )
        #expect(notice.messageKey != SupervisionNotice.paused(failures: 1).messageKey)

        // The failures-exhausted pause keeps its own message.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 5,
                isAutoRestartWanted: false,
                pauseReason: .repeatedStartFailures(count: 5)
            ).messageKey == SupervisionNotice.paused(failures: 5).messageKey
        )
    }

    // MARK: - Paused message grammar

    /// The codebase has no pluralization infrastructure, so the English wording
    /// must read correctly for every count instead of rendering
    /// “It failed 1 times in a row”.
    @Test
    func thePausedMessageReadsCorrectlyForAnyFailureCount() throws {
        let english = try Self.loadStrings("en")
        let key = "已连续失败 %lld 次，自动重启已暂停；请点击“启动模型”手动重试，并查看日志排查原因。"
        let value = try #require(english[key], "the failures-pause key must be translated")

        #expect(value.contains("%lld"), "the count must still be reported")
        #expect(
            !value.contains("%lld times"),
            "“%lld times” renders “1 times”; use wording that reads for any count"
        )
    }

    // MARK: - Show parked models before offering a re-download

    /// `ModelStorageManager` reports `.originalModelsParked` when an entry the
    /// launcher did not create occupies the canonical path. `refreshModelStorage`
    /// must preserve the notice from the same storage snapshot,
    /// so `installationStatus` stays accurate and the full-window installer does not
    /// invite ~7.8 GB of downloading while ~7 GB sits in the hidden sibling.


    /// Only the parked state is a recovery; a retained legacy copy is reported
    /// through the migration outcome instead, and an ordinary missing model is
    /// still an ordinary download.


    /// The already-correct dangling-link path must not be weakened: a canonical
    /// path that does not resolve is unavailable, has no download prompt at all
    /// (only 重新检测), and must not be reported as a parked copy.


    // MARK: - Retained model location survives a relaunch

    /// `modelMigrationOutcome` is in-memory only, so a retained duplicate became
    /// invisible as soon as the app was quit and reopened. The record is
    /// persisted and re-validated on every storage refresh.
    @Test
    @MainActor
    func aRetainedSourceDuplicateSurvivesARelaunch() async throws {
        let context = try makeContext("uiw-retained")
        defer { context.cleanUp() }

        // A migration reported the old location as undeletable.
        let legacy = context.root.appending(path: "old-models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: legacy.appending(path: "model.gguf"))

        try context.config.setModelsDirectory(context.config.modelsDirectory, retainedSource: legacy)

        // Relaunch: a new controller over the same defaults must still know.
        let relaunched = context.makeController()
        await relaunched.refreshModelStorage()

        #expect(relaunched.retainedSourceModelLocation?.path == legacy.path)
        #expect(relaunched.retainedSourceModelBytes == (try ManagedFileSystem.allocatedBytes(at: legacy)))

        // … and the message names the location, so the user can act on it.
        let message = try #require(relaunched.retainedSourceModelMessage)
        #expect(message.contains(legacy.path))
        #expect(!message.contains("%@"), "both placeholders must be filled in")
    }

    /// Once the folder is gone the information must stop being reported, so a
    /// cleaned-up duplicate does not haunt the UI forever.
    @Test
    @MainActor
    func aRetainedSourceDuplicateStopsBeingReportedOnceGone() async throws {
        let context = try makeContext("uiw-retained-gone")
        defer { context.cleanUp() }

        let legacy = context.root.appending(path: "old-models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let controller = context.makeController()
        try context.config.setModelsDirectory(context.config.modelsDirectory, retainedSource: legacy)
        await controller.refreshModelStorage()
        #expect(controller.retainedSourceModelMessage != nil)

        try FileManager.default.removeItem(at: legacy)
        await controller.refreshModelStorage()

        #expect(controller.retainedSourceModelLocation == nil)
        #expect(controller.retainedSourceModelMessage == nil)
    }

    // MARK: - The launcher remembers the server it started

    /// Quitting the launcher leaves the model running by design, so the process
    /// manager's PID record survives the app. The launch options did not, so the
    /// next launch saw *its own* server as an unknown one and
    /// `chatAffordanceIsUnreliable` replaced the chat button with the API
    /// address — a false negative in the app's most common flow
    /// (launch → quit → reopen).
    @Test
    @MainActor
    func aRelaunchedLauncherStillRecognisesTheServerItStarted() async throws {
        let context = try makeContext("uiw-relaunch")
        defer { context.cleanUp() }
        try makeCompleteInstallation(config: context.config)

        let process = StubServerProcessManager()
        let first = context.makeController(
            stub: process,
            healthProbe: { _ in process.isRunningValue }
        )
        first.recheckInstallation()
        await first.refresh()
        #expect(first.status == .stopped)
        await first.start()

        #expect(first.status == .running)
        #expect(first.canOpenChat)
        #expect(
            primaryAction(for: first, status: .running, hasUnownedServer: false) == .openChat
        )

        // The launcher quits. The server keeps running and the PID record
        // survives; only the in-memory options are gone.
        let relaunched = context.makeController(
            stub: process,
            healthProbe: { _ in process.isRunningValue }
        )
        await relaunched.refresh()
        await relaunched.refresh()

        #expect(relaunched.status == .running)
        #expect(relaunched.activeLaunchOptions == first.activeLaunchOptions)
        #expect(!relaunched.runningServerOptionsAreUnknown)
        #expect(!relaunched.chatAffordanceIsUnreliable)
        #expect(relaunched.canOpenChat)
        #expect(
            primaryAction(for: relaunched, status: .running, hasUnownedServer: false) == .openChat
        )
    }

    /// The genuine unknown case stays suppressed. A server this launcher never
    /// recorded options for — hand-run and only *adopted* on this pass — must
    /// not be advertised as serving the bundled chat page, not even when a stale
    /// record from an earlier run is still on disk.
    @Test
    @MainActor
    func anAdoptedServerKeepsUnknownLaunchOptions() async throws {
        let context = try makeContext("uiw-adopted-unknown")
        defer { context.cleanUp() }
        try makeCompleteInstallation(config: context.config)

        let process = StubServerProcessManager()
        let first = context.makeController(
            stub: process,
            healthProbe: { _ in process.isRunningValue }
        )
        first.recheckInstallation()
        await first.refresh()
        await first.start()
        #expect(first.activeLaunchOptions != nil)

        // The PID record is gone (reclaimed plist, migrated install) while the
        // server keeps running, so the next launcher can only adopt it.
        process.isRunningValue = false
        process.discovered = ServerProcessDescriptor(
            pid: 4242,
            executablePath: "/tmp/llama-server",
            isManaged: false
        )
        process.adoptSucceeds = true

        let relaunched = context.makeController(stub: process, healthProbe: { _ in true })
        await relaunched.refresh()
        #expect(relaunched.status == .external)
        #expect(process.adoptCallCount == 0)
        #expect(await relaunched.adoptUnownedServer())
        await relaunched.refresh()
        await relaunched.refresh()

        #expect(relaunched.status == .running)
        #expect(relaunched.activeLaunchOptions == nil)
        #expect(relaunched.runningServerOptionsAreUnknown)
        #expect(relaunched.chatAffordanceIsUnreliable)
        #expect(
            primaryAction(for: relaunched, status: .running, hasUnownedServer: false)
                == .copyAPIAddress
        )
    }

    // MARK: - Re-derive the parked-copy notice when the user acts

    /// The reviewer's sequence: the notice appears, the user acts on it by
    /// trashing `.models.previous` in Finder, then presses 重新检测 — and the
    /// notice still claimed the bytes were retained and offered to reveal a
    /// folder that no longer existed. `recheckInstallation()` never re-derived
    /// the storage snapshot, and deleting the folder flips none of the
    /// availability flags `refreshModelLocationAvailability()` watches.


    /// The affordance behind 重新检测 also re-takes the storage snapshot, so the
    /// re-derivation works in both directions: a copy that reappears is picked
    /// up again instead of the notice being lost until the next relaunch.


    /// The reveal action must not offer to open a path that is gone: the
    /// reviewer saw it raise the "cannot open the model directory in Finder"
    /// alert for a folder the user had just trashed.


    // MARK: - Confirm before re-downloading parked models

    /// The install screen led with an *enabled* 开始安装 while a complete copy
    /// sat in `.models.previous`, so one click could still start a needless
    /// ~7.8 GB transfer: the parked notice was only a secondary amber banner.


    // MARK: - Crash evidence reaches the pause message

    /// `ServiceController.crashesInCrashWindow` documents itself as the crash
    /// evidence the notice reports "even in the reason that does not carry it".
    /// The failures-exhausted pause is `.repeatedStartFailures(count:)`, which
    /// carries no crash count, so the notice reported only the flat failure
    /// count while the published crash history had no product reader at all.
    @Test
    func theFailuresPauseReportsCrashesFromTheCrashWindow() {
        let failures = AutoRestartSupervision.maximumConsecutiveFailures
        let notice = StudioPresentation.supervisionNotice(
            consecutiveFailures: failures,
            isAutoRestartWanted: false,
            pauseReason: .repeatedStartFailures(count: failures),
            crashesInCrashWindow: 2
        )

        #expect(notice == .pausedAfterCrashes(failures: failures, crashes: 2))
        #expect(
            notice.messageKey
                == "已连续失败 %lld 次，期间还崩溃 %lld 次；自动重启已暂停，请点击“启动模型”手动重试，并查看日志排查原因。"
        )
        #expect(notice.messageKey != SupervisionNotice.paused(failures: failures).messageKey)

        // Without crash evidence the plain failure sentence is unchanged.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: failures,
                isAutoRestartWanted: false,
                pauseReason: .repeatedStartFailures(count: failures)
            ) == .paused(failures: failures)
        )
        // A crash loop keeps its own sentence whatever the window count is.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 1,
                isAutoRestartWanted: false,
                pauseReason: .crashLoop(crashesInWindow: 3),
                crashesInCrashWindow: 3
            ) == .pausedByCrashLoop(crashes: 3, failures: 1)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func primaryAction(
        for controller: ServiceController,
        status: ServiceStatus,
        hasUnownedServer: Bool
    ) -> StudioPrimaryAction {
        StudioPresentation.primaryAction(
            status: status,
            isBusy: controller.isBusy,
            hasUnownedServer: hasUnownedServer,
            unownedServerIsForeign: controller.unownedServerIsForeign,
            canOpenChat: controller.canOpenChat,
            chatOptionsAreUnknown: controller.chatAffordanceIsUnreliable
        )
    }

    /// An isolated config + defaults + controller factory, cleaned up by `cleanUp()`.
    private struct Context {
        let config: LauncherConfig
        let defaults: UserDefaults
        let suiteName: String
        let root: URL

        @MainActor
        func makeController(
            stub: StubServerProcessManager = StubServerProcessManager(),
            healthProbe: @escaping @Sendable (URL) async -> Bool = { _ in false },
            loginItemStatus: @escaping @Sendable () -> SMAppService.Status = { .notRegistered },
            hardware: HardwareRequirements = .current(),
            installationRunner: ServiceController.InstallationRunner? = nil,
            openDirectory: @escaping (URL) -> Bool = { _ in true },
            fastHealth: Bool = false,
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
        ) -> ServiceController {
            ServiceController(
                config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
                processManager: stub,
                defaults: defaults,
                openDirectory: openDirectory,
                healthProbe: healthProbe,
                loginItemStatus: loginItemStatus,
                hardwareRequirements: hardware,
                installationRunner: installationRunner,
                healthStartTimeout: fastHealth ? .milliseconds(20) : .seconds(90),
                healthStopTimeout: fastHealth ? .milliseconds(20) : .seconds(20),
                healthPollInterval: fastHealth ? .milliseconds(1) : .seconds(1),
                now: now
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeContext(_ label: String) throws -> Context {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: root.path],
            homeDirectory: root
        )
        let suiteName = "Launcher27B-\(label)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Context(config: config, defaults: defaults, suiteName: suiteName, root: root)
    }

    /// A stranger entry at the canonical models path plus the hidden sibling the
    /// launcher parks the original models in.
    @discardableResult
    private func makeParkedModelCopy(config: LauncherConfig) throws -> URL {
        let models = config.modelsDirectory
        let backup = models.deletingLastPathComponent().appending(
            path: ".models.previous",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 64).write(to: models.appending(path: "stranger.bin"))
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 65_536).write(to: backup.appending(path: "model.gguf"))
        return backup
    }

    /// Creates a sparse file of exactly `byteCount` bytes; the installation
    /// inspector accepts a `.file` artifact on size alone.
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

    private static func loadStrings(_ language: String) throws -> [String: String] {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let candidate = url
                .appendingPathComponent("Sources/Launcher27B/Resources")
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                return try #require(plist as? [String: String])
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
