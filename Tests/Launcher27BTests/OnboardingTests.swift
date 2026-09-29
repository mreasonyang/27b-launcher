import Foundation
import Testing
import SwiftUI
import AppKit
@testable import Launcher27B

@Suite @MainActor
struct OnboardingTests {
    private struct Fixture {
        let root: URL
        let config: LauncherConfig
        let defaults: UserDefaults
        let suite: String
        let prefs: AppPreferences
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() throws -> Fixture {
        let suite = "27b-onboarding-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = LauncherConfig.makeLocalInstallation(environment: [LauncherConfig.supportDirectoryOverrideKey: root.path], homeDirectory: root)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let prefs = AppPreferences(defaults: defaults)
        prefs.language = .english
        return Fixture(root: root, config: config, defaults: defaults, suite: suite, prefs: prefs)
    }

    nonisolated private static func installFixtures(_ config: LauncherConfig) throws {
        let runtime = config.serverBinary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data().write(to: config.serverBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config.serverBinary.path)
        try Data().write(to: runtime.appending(path: "libllama-server-impl.dylib"))
        try InstallationCatalog.runtimeRelease.write(to: runtime.appending(path: ".llama_release"), atomically: true, encoding: .utf8)
        for artifact in InstallationCatalog().artifacts(for: config) {
            guard case .file = artifact.kind else { continue }
            try FileManager.default.createDirectory(at: artifact.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: artifact.destinationURL)
            let file = try FileHandle(forWritingTo: artifact.destinationURL)
            try file.truncate(atOffset: UInt64(artifact.expectedByteCount))
            try file.close()
        }
    }

    private func controller(_ f: Fixture, process: StubServerProcessManager = StubServerProcessManager(),
                            hardware: HardwareRequirements = .init(architecture: "arm64", physicalMemoryBytes: 32 * 1_073_741_824),
                            space: Int64 = 20_000_000_000,
                            open: @escaping (URL) -> Bool = { _ in false },
                            modelIDLoader: (@Sendable (URL) async throws -> String)? = nil,
                            runner: ServiceController.InstallationRunner? = nil) -> ServiceController {
        let config = f.config
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [OnboardingMetricsProtocol.self]
        return ServiceController(config: config, requiresInstanceLock: false, preferences: f.prefs,
            processManager: process, metricsClient: LlamaMetricsClient(session: URLSession(configuration: transport)),
            defaults: f.defaults, openChatURL: open,
            modelIdentifierLoader: modelIDLoader ?? { _ in config.modelFile.path },
            spaceReporter: { _ in [InstallationVolumeSpace(volume: config.supportDirectory, requiredBytes: 9_000_000_000, availableBytes: space)] },
            healthProbe: { _ in process.isRunningValue }, loginItemStatus: { .notRegistered },
            hardwareRequirements: hardware,
            installationRunner: runner ?? { _, _ in try Self.installFixtures(config) },
            healthStartTimeout: .milliseconds(50), healthPollInterval: .milliseconds(1))
    }

    private func settle(_ c: ServiceController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while c.isDownloadInProgress || c.isBusy || c.isPreparingQuickStart {
            try #require(ContinuousClock.now < deadline, "Preparation did not settle")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func existingInstallationAndDeferredRouting() {
        for deferred in [false, true] {
            #expect(QuickStartRoute.resolve(installation: .ready, presented: false, deferred: deferred, completed: false) == .setup)
            #expect(QuickStartRoute.resolve(installation: .ready, presented: false, deferred: deferred, completed: true) == .dashboard)
            #expect(QuickStartRoute.resolve(installation: .ready, presented: true, deferred: deferred, completed: true) == .setup)
        }
        for status in [InstallationStatus.required, .failed, .checking, .installing] {
            for completed in [false, true] {
                #expect(QuickStartRoute.resolve(installation: status, presented: false, deferred: false, completed: completed) == .setup)
                #expect(QuickStartRoute.resolve(installation: status, presented: false, deferred: true, completed: completed) == .deferred)
            }
        }
    }

    @Test func laterChoiceSurvivesRelaunchAndCanBeReopened() throws {
        let f = try fixture(); defer { f.clean() }
        let c = controller(f); c.recheckInstallation()
        c.dismissQuickStart()
        #expect(c.quickStartRoute == .deferred)
        #expect(AppPreferences(defaults: f.defaults).setupDeferred)
        #expect(!AppPreferences(defaults: f.defaults).onboardingCompleted)
        c.showQuickStart()
        #expect(c.quickStartRoute == .setup)
        #expect(!AppPreferences(defaults: f.defaults).setupDeferred)
    }

    @Test func freshInstallationLoadsOnceButNeverOpensBrowserAutomatically() async throws {
        let f = try fixture(); defer { f.clean() }
        let process = StubServerProcessManager()
        var opens = 0
        let c = controller(f, process: process, open: { _ in opens += 1; return true })
        c.recheckInstallation()
        #expect(c.installationStatus == .required)
        await c.beginGuidedInstallation()
        try await settle(c)
        #expect(c.installationStatus == .ready)
        #expect(c.status == .running)
        #expect(process.startCallCount == 1)
        #expect(process.lastLaunchOptions?.ablationStrength == .aggressive)
        #expect(process.lastLaunchOptions?.ablationEnabled == true)
        #expect(opens == 0)
        #expect(c.quickStartRoute == .setup)
        #expect(!f.prefs.onboardingCompleted)
        #expect(!c.autoStartEnabled)
        #expect(c.bindMode == .loopback)
        #expect(c.openChat())
        #expect(opens == 1)
        c.dismissQuickStart()
        #expect(c.quickStartRoute == .dashboard)
    }

    @Test func ordinaryRepairDoesNotInventFirstRunIntent() async throws {
        let f = try fixture(); defer { f.clean() }
        f.prefs.onboardingCompleted = true
        let process = StubServerProcessManager()
        let c = controller(f, process: process)
        c.recheckInstallation()
        c.beginInstallation()
        try await settle(c)
        #expect(c.installationStatus == .ready)
        #expect(process.startCallCount == 0)
        #expect(c.quickStartRoute == .dashboard)
    }

    @Test func diskAndHardwareBlockBeforeRunner() async throws {
        for (arch, memory, space) in [("arm64", UInt64(8), Int64(20_000_000_000)), ("x86_64", 32, 20_000_000_000), ("arm64", 32, 1)] {
            let f = try fixture(); defer { f.clean() }
            let process = StubServerProcessManager()
            let c = controller(f, process: process, hardware: .init(architecture: arch, physicalMemoryBytes: memory * 1_073_741_824), space: space,
                               runner: { _, _ in Issue.record("Blocked preflight must not download") })
            c.recheckInstallation()
            await c.beginGuidedInstallation()
            #expect(!c.isDownloadInProgress)
            #expect(process.startCallCount == 0)
            #expect(!c.canBeginGuidedInstallation)
        }
    }

    @Test func limitedMemoryWarningStillAllowsPreparation() async throws {
        let f = try fixture(); defer { f.clean() }
        let c = controller(f, hardware: .init(architecture: "arm64", physicalMemoryBytes: 16 * 1_073_741_824))
        c.recheckInstallation()
        await c.refreshInstallationSpace()
        #expect(c.hardwareIssueMessage != nil)
        #expect(c.canBeginGuidedInstallation)
    }

    @Test func unreadableSpaceFailsClosedAndCanBeRechecked() async throws {
        let f = try fixture(); defer { f.clean() }
        let c = ServiceController(config: f.config, requiresInstanceLock: false, preferences: f.prefs,
            processManager: StubServerProcessManager(), defaults: f.defaults,
            spaceReporter: { _ in throw CocoaError(.fileReadNoPermission) }, healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
        c.recheckInstallation()
        await c.beginGuidedInstallation()
        #expect(c.installationSpace == nil)
        #expect(c.installationSpaceError != nil)
        #expect(!c.canBeginGuidedInstallation)
    }

    @Test func pauseCancelsPreparationAndPreservesRetry() async throws {
        let f = try fixture(); defer { f.clean() }
        let process = StubServerProcessManager()
        let c = controller(f, process: process, runner: { _, _ in try await Task.sleep(for: .seconds(30)) })
        c.recheckInstallation()
        await c.beginGuidedInstallation()
        c.dismissQuickStart()
        #expect(c.quickStartPresented) // cannot dismiss an active operation
        c.cancelInstallation()
        try await settle(c)
        #expect(c.installationStatus == .required)
        #expect(process.startCallCount == 0)
        #expect(!c.isCancellingInstallation)
    }

    @Test func downloadFailureDoesNotLoadOrOpenAndStaysActionable() async throws {
        let f = try fixture(); defer { f.clean() }
        let process = StubServerProcessManager()
        let c = controller(f, process: process, runner: { _, _ in throw URLError(.notConnectedToInternet) })
        c.recheckInstallation()
        await c.beginGuidedInstallation()
        try await settle(c)
        #expect(c.installationStatus == .failed)
        #expect(c.installationError != nil)
        #expect(process.startCallCount == 0)
        #expect(c.quickStartRoute == .setup)
    }

    @Test func failedStartRetriesWithoutRedownloading() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        let process = StubServerProcessManager()
        process.startError = ServerProcessError.healthCheckTimedOut
        let c = controller(f, process: process, runner: { _, _ in Issue.record("No download needed") })
        await c.monitorSetup()
        c.showQuickStart()
        await c.prepareModelForQuickStart()
        #expect(c.installationStatus == .ready)
        #expect(c.status == .stopped)
        #expect(c.latestError != nil)
        #expect(!c.hasPresentedError)
        #expect(!c.isAutoRestartWanted)
        process.startError = nil
        await c.prepareModelForQuickStart()
        #expect(c.status == .running)
        #expect(c.latestError == nil)
        #expect(process.startCallCount == 2)
    }

    @Test func loaderExitEndsPreparationBeforeTheHealthTimeout() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        let process = StubServerProcessManager()
        let c = ServiceController(config: f.config, requiresInstanceLock: false,
            preferences: f.prefs, processManager: process, defaults: f.defaults,
            healthProbe: { _ in
                process.isRunningValue = false
                return false
            }, loginItemStatus: { .notRegistered },
            healthStartTimeout: .seconds(30), healthPollInterval: .milliseconds(1))
        await c.monitorSetup()
        let started = ContinuousClock.now
        await c.prepareModelForQuickStart()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(c.status == .stopped)
        #expect(c.latestError == ServerProcessError.exitedBeforeReady.localizedDescription(using: f.prefs))
        #expect(!c.isAutoRestartWanted)
        #expect(!c.isPreparingQuickStart)
        #expect(c.canStart)
    }

    @Test func browserFailureKeepsReadyPageAndRetryClearsError() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        var succeed = false
        let c = controller(f, open: { _ in succeed })
        await c.monitorSetup()
        c.showQuickStart()
        await c.prepareModelForQuickStart()
        #expect(!c.openChat())
        #expect(c.chatOpenError != nil)
        #expect(c.quickStartRoute == .setup)
        succeed = true
        #expect(c.openChat())
        #expect(c.chatOpenError == nil)
    }

    @Test func LANAndUnknownServicesNeverOpenChat() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        f.defaults.set(ServerBindMode.allInterfaces.rawValue, forKey: "serverBindMode")
        let c = controller(f, open: { _ in Issue.record("LAN must not open chat"); return true })
        await c.monitorSetup()
        await c.prepareModelForQuickStart()
        #expect(c.status == .running)
        #expect(!c.openChat())
        let process = StubServerProcessManager()
        process.isRunningValue = true // no recorded launch options
        let unknown = controller(f, process: process, open: { _ in Issue.record("Unknown must not open chat"); return true })
        await unknown.refresh()
        #expect(unknown.chatAffordanceIsUnreliable)
        #expect(!unknown.openChat())
    }

    @Test func installedFilesStillRequireFirstRunGuideUntilUserFinishes() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        let process = StubServerProcessManager()
        let c = controller(f, process: process)
        await c.monitorSetup()
        #expect(c.installationStatus == .ready)
        #expect(c.quickStartRoute == .setup)
        #expect(!c.isDownloadInProgress)
        #expect(!AppPreferences(defaults: f.defaults).onboardingCompleted)
        #expect(process.startCallCount == 0)
        // Closing/relaunching without an explicit finish must keep the guide.
        let unfinished = controller(f, process: process)
        await unfinished.monitorSetup()
        #expect(unfinished.quickStartRoute == .setup)
        c.dismissQuickStart()
        #expect(AppPreferences(defaults: f.defaults).onboardingCompleted)
        #expect(c.quickStartRoute == .dashboard)
        let finished = controller(f, process: process)
        await finished.monitorSetup()
        #expect(finished.quickStartRoute == .dashboard)
        c.showQuickStart()
        #expect(c.quickStartRoute == .setup)
        #expect(process.startCallCount == 0)
        c.dismissQuickStart()
        #expect(c.quickStartRoute == .dashboard)
    }

    @Test func connectionModelIDCanRetryWithoutSendingTheUserElsewhere() async throws {
        let f = try fixture(); defer { f.clean() }
        try Self.installFixtures(f.config)
        actor Loader {
            var attempts = 0
            func load() throws -> String {
                attempts += 1
                if attempts == 1 { throw URLError(.timedOut) }
                return "Actual-Case-Sensitive-Model"
            }
        }
        let loader = Loader()
        let process = StubServerProcessManager()
        let c = controller(f, process: process, modelIDLoader: { _ in try await loader.load() })
        await c.monitorSetup()
        await c.refreshConnectionModelID()
        #expect(await loader.attempts == 0)
        await c.prepareModelForQuickStart()
        await c.refreshConnectionModelID()
        #expect(c.connectionModelIDFailed)
        #expect(c.connectionModelID == nil)
        await c.refreshConnectionModelID()
        #expect(!c.connectionModelIDFailed)
        #expect(c.connectionModelID == "Actual-Case-Sensitive-Model")
    }

    @Test func secondaryInstanceCannotPrepareOrStart() async throws {
        let f = try fixture(); defer { f.clean() }
        let process = StubServerProcessManager()
        let c = ServiceController(config: f.config, preferences: f.prefs,
            processManager: process, defaults: f.defaults,
            healthProbe: { _ in false }, loginItemStatus: { .notRegistered },
            installationRunner: { _, _ in Issue.record("Secondary must not install") })
        c.recheckInstallation()
        await c.beginGuidedInstallation()
        await c.prepareModelForQuickStart()
        #expect(!c.isDownloadInProgress)
        #expect(process.startCallCount == 0)
    }

    @Test func startRechecksSpaceInsteadOfTrustingDisplayedSnapshot() async throws {
        let f = try fixture(); defer { f.clean() }
        actor Capacity {
            var free: Int64 = 20_000_000_000
            func setLow() { free = 0 }
        }
        let capacity = Capacity()
        let storageURL = f.config.supportDirectory
        let c = ServiceController(config: f.config, requiresInstanceLock: false, preferences: f.prefs,
            processManager: StubServerProcessManager(), defaults: f.defaults,
            spaceReporter: { _ in [InstallationVolumeSpace(volume: storageURL,
                requiredBytes: 9_000_000_000, availableBytes: await capacity.free)] },
            healthProbe: { _ in false }, loginItemStatus: { .notRegistered },
            hardwareRequirements: .init(architecture: "arm64", physicalMemoryBytes: 32 * 1_073_741_824),
            installationRunner: { _, _ in Issue.record("Stale space must not authorize download") })
        c.recheckInstallation()
        await c.refreshInstallationSpace()
        #expect(c.canBeginGuidedInstallation)
        await capacity.setLow()
        await c.beginGuidedInstallation()
        #expect(!c.isDownloadInProgress)
        #expect(!c.canBeginGuidedInstallation)
    }

    @Test func nativeSetupAndReadyViewsFitAllLocalesAtMinimumSize() async throws {
        let f = try fixture(); defer { f.clean() }
        let c = controller(f)
        c.recheckInstallation()
        await c.refreshInstallationSpace()
        for ready in [false, true] {
            if ready {
                try Self.installFixtures(f.config)
                await c.monitorSetup()
                c.showQuickStart()
                await c.prepareModelForQuickStart()
            }
            for language in AppLanguage.allCases {
                f.prefs.language = language
                for dark in [false, true] {
                    // Measure unconstrained content height: a fixed outer frame alone
                    // can pass even when children overflow or are clipped.
                    let natural = NSHostingView(rootView: StudioInstallerOverlay(controller: c)
                        .environment(f.prefs).environment(\.locale, language.locale)
                        .frame(width: 800).fixedSize(horizontal: false, vertical: true))
                    natural.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                    natural.layoutSubtreeIfNeeded()
                    #expect(natural.fittingSize.height <= 560,
                        "Onboarding overflows: ready=\(ready), language=\(language.rawValue), size=\(natural.fittingSize)")
                    let view = LauncherView(controller: c)
                        .environment(f.prefs)
                        .environment(\.locale, language.locale)
                        .preferredColorScheme(dark ? .dark : .light)
                        .frame(width: 800, height: 560)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    // Allow SwiftUI's task and layout passes to finish before capture.
                    try await Task.sleep(for: .milliseconds(30))
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width <= 800)
                    #expect(host.fittingSize.height <= 560)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= 800)
                    #expect(bitmap.pixelsHigh >= 560)
                    if let output = ProcessInfo.processInfo.environment["LAUNCHER27B_QA_OUTPUT"] {
                        let directory = URL(filePath: output)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: directory.appending(path: "\(ready ? "ready" : "prepare")-\(language.rawValue)-\(dark ? "dark" : "light")-800x560.png"))
                        if ready {
                            let connection = NSHostingView(rootView: QuickStartConnectionInfo(controller: c)
                                .environment(f.prefs).environment(\.locale, language.locale)
                                .frame(width: 640))
                            connection.appearance = host.appearance
                            connection.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
                            connection.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(30))
                            connection.layoutSubtreeIfNeeded()
                            #expect(connection.fittingSize.width <= 640)
                            #expect(connection.fittingSize.height <= 420)
                            try savePNG(connection, url: directory.appending(path: "connection-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }

    @Test func onboardingWarningsAndFailuresFitWithoutScrolling() async throws {
        for language in AppLanguage.allCases {
            for scenario in ["hardware", "space", "download", "network", "verify", "failure", "browser", "modelID"] {
                let f = try fixture(); defer { f.clean() }
                f.prefs.language = language
                let downloading = ["download", "network", "verify"].contains(scenario)
                let modelID = f.config.modelFile.path
                let c = controller(f,
                    hardware: .init(architecture: "arm64", physicalMemoryBytes: (scenario == "hardware" ? 8 : 32) * 1_073_741_824),
                    space: scenario == "space" ? 1 : 20_000_000_000,
                    modelIDLoader: { _ in
                        if scenario == "modelID" { throw URLError(.timedOut) }
                        return modelID
                    },
                    runner: { _, progress in
                        if downloading {
                            await progress(InstallationProgress(component: .model,
                                phase: scenario == "network" ? .waitingForNetwork : scenario == "verify" ? .verifying : .downloading,
                                isResuming: false, componentCompletedBytes: 2_000_000_000, componentTotalBytes: 8_000_000_000,
                                overallCompletedBytes: 2_000_000_000, overallTotalBytes: 8_000_000_000,
                                bytesPerSecond: 10_000_000, estimatedTimeRemaining: 600))
                            try await Task.sleep(for: .seconds(30))
                        }
                        throw URLError(.notConnectedToInternet)
                    })
                c.recheckInstallation()
                await c.refreshInstallationSpace()
                if scenario == "failure" || downloading {
                    await c.beginGuidedInstallation()
                    if scenario == "failure" { try await settle(c) }
                } else if scenario == "browser" || scenario == "modelID" {
                    try Self.installFixtures(f.config)
                    await c.monitorSetup()
                    await c.prepareModelForQuickStart()
                    await c.refreshConnectionModelID()
                    if scenario == "browser" { #expect(!c.openChat()) }
                }
                let host = NSHostingView(rootView: StudioInstallerOverlay(controller: c)
                    .environment(f.prefs).environment(\.locale, language.locale)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 800).fixedSize(horizontal: false, vertical: true))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                if scenario == "browser" {
                    #expect(c.connectionModelID == modelID)
                }
                #expect(host.fittingSize.height <= 560,
                    "\(scenario) / \(language.rawValue) needs \(host.fittingSize.height) pt")
                if let output = ProcessInfo.processInfo.environment["LAUNCHER27B_QA_OUTPUT"], scenario == "browser" {
                    let url = URL(filePath: output)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    host.frame.size = host.fittingSize
                    try savePNG(host, url: url.appending(path: "browser-error-\(language.rawValue).png"))
                }
                if downloading { c.cancelInstallation(); try await settle(c) }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func nativeWindowReclaimsSpaceAfterUnownedServiceChoice(stop: Bool, initiallyOversized: Bool) async throws {
        let f = try fixture(); defer { f.clean() }
        f.prefs.language = .simplifiedChinese
        f.prefs.onboardingCompleted = true
        try Self.installFixtures(f.config)
        let process = StubServerProcessManager()
        process.discovered = ServerProcessDescriptor(pid: 12345,
            executablePath: f.config.serverBinary.path, isManaged: false)
        let c = ServiceController(config: f.config, requiresInstanceLock: false, preferences: f.prefs,
            processManager: process, defaults: f.defaults,
            healthProbe: { _ in process.discovered != nil || process.isRunningValue },
            loginItemStatus: { .notRegistered })
        await c.monitorSetup()
        #expect(c.unownedServer != nil)

        let host = NSHostingView(rootView: LauncherView(controller: c)
            .environment(f.prefs).environment(\.locale, f.prefs.language.locale))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 860, height: initiallyOversized ? 900 : 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        // Exercise real AppKit layout and the production SwiftUI modifier.
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let expanded = window.frame
        #expect(expanded.height > 600)
        try saveWindowEvidence(host, name: stop ? "stop-before" : "adopt-before")
        if stop { await c.stopUnownedServer() }
        else { #expect(await c.adoptUnownedServer()) }
        #expect(c.unownedServer == nil)
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let compact = window.frame
        #expect(compact.height < expanded.height - 40)
        #expect(abs(compact.maxY - expanded.maxY) < 1)
        #expect(window.contentLayoutRect.height >= LauncherTheme.windowMinimumHeight)
        try saveWindowEvidence(host, name: stop ? "stop-after" : "adopt-after")
        print("Window notice \(stop ? "stop" : "adopt"): \(expanded.height) -> \(compact.height)")

        // AppKit's live-resize notification must opt out of subsequent auto-fit.
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        var chosen = window.frame
        chosen.size.height += 80
        window.setFrame(chosen, display: true)
        process.isRunningValue = false
        process.discovered = ServerProcessDescriptor(pid: 12346,
            executablePath: f.config.serverBinary.path, isManaged: false)
        await c.refresh()
        #expect(c.unownedServer != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(window.frame.height - chosen.height) < 1)
    }

    private func saveWindowEvidence(_ host: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LAUNCHER27B_WINDOW_QA_OUTPUT"] else { return }
        let directory = URL(filePath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try savePNG(host, url: directory.appending(path: name + ".png"))
    }

    private func savePNG(_ host: NSView, url: URL) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    @Test func installerReportIncludesReserveAndIsTheEnforcedBudget() async throws {
        let f = try fixture(); defer { f.clean() }
        let installer = BonsaiInstaller(config: f.config, availableCapacity: { _ in 1 })
        let artifacts = InstallationCatalog().artifacts(for: f.config)
        let report = try await installer.diskSpaceReport(for: artifacts)
        let requirements = try await installer.diskSpaceRequirements(for: artifacts)
        #expect(!report.isEmpty)
        for volume in report {
            #expect(volume.requiredBytes == requirements[volume.volume]! + 1_073_741_824)
            #expect(!volume.isSufficient)
        }
    }
}

/// Onboarding tests must not depend on a real model listening on localhost.
private final class OnboardingMetricsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload = """
        llamacpp:prompt_tokens_total 0
        llamacpp:prompt_tokens_cached_total 0
        llamacpp:tokens_predicted_total 0
        llamacpp:prompt_tokens_seconds 0
        llamacpp:predicted_tokens_seconds 0
        llamacpp:requests_processing 0
        llamacpp:requests_deferred 0
        llamacpp:n_tokens_max 0
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
