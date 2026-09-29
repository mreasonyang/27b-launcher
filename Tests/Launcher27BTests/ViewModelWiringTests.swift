import Foundation
import Testing
@testable import Launcher27B

/// Guards the state-to-presentation mapping that closes the broken intermediate
/// states: the LAN-mode chat entry point, the unowned-server actions, the
/// supervision budget, and the pre-download hardware refusal.
///
/// These assert the pure resolvers in `LauncherView.swift` against a real
/// `ServiceController`, so changes to the controller's published
/// state or the view's decision shows up here without a UI test.
///
/// `StubServerProcessManager` is shared with `ServiceControllerLifecycleTests`.
@Suite
struct ViewModelWiringTests {
    // MARK: - Chat entry points

    @Test
    @MainActor
    func heroOffersTheAPIAddressInsteadOfChatInLANMode() async throws {
        let context = try makeContext("wiring-chat")
        defer { context.cleanUp() }

        let controller = context.makeController()

        #expect(controller.bindMode == .loopback)
        #expect(controller.canOpenChat)
        #expect(primaryAction(for: controller, status: .running) == .openChat)

        // `setBindMode` parks the LAN switch until it is explicitly confirmed.
        await controller.setBindMode(.allInterfaces)
        #expect(controller.isBindModeChangePending)
        #expect(controller.canOpenChat)

        await controller.confirmBindMode(.allInterfaces)
        #expect(controller.bindMode == .allInterfaces)
        #expect(!controller.canOpenChat)

        // The server now runs with `--no-webui`, so the hero must not offer the
        // (non-existent) bundled chat page in either reachable state.
        #expect(primaryAction(for: controller, status: .running) == .copyAPIAddress)
        #expect(primaryAction(for: controller, status: .external) == .copyAPIAddress)

        // Switching back is always safe and restores the chat affordance.
        await controller.setBindMode(.loopback)
        #expect(controller.canOpenChat)
        #expect(primaryAction(for: controller, status: .running) == .openChat)
    }

    @Test
    @MainActor
    func heroAdoptsAnUnmanagedServerInsteadOfOpeningChat() async throws {
        let context = try makeContext("wiring-unowned")
        defer { context.cleanUp() }

        let stub = StubServerProcessManager()
        stub.isRunningValue = false
        stub.adoptSucceeds = false
        stub.discovered = ServerProcessDescriptor(
            pid: 4242,
            executablePath: "/tmp/llama-server",
            isManaged: false
        )

        let controller = context.makeController(
            stub: stub,
            healthProbe: { _ in true }
        )

        await controller.refresh()

        #expect(controller.unownedServer?.pid == 4242)
        #expect(controller.status == .external)
        #expect(controller.canStopUnownedServer)
        #expect(!controller.canStart)
        #expect(primaryAction(for: controller, status: controller.status) == .adoptUnownedServer)
    }

    @Test
    func primaryActionEnabledFollowsTheResolvedAction() {
        #expect(!StudioPresentation.isPrimaryActionEnabled(.start, canStart: false, isBusy: false))
        #expect(StudioPresentation.isPrimaryActionEnabled(.start, canStart: true, isBusy: false))
        // A cloud-free substitute for chat must stay clickable even when Start
        // is impossible (the service is already up).
        #expect(StudioPresentation.isPrimaryActionEnabled(.openChat, canStart: false, isBusy: false))
        #expect(StudioPresentation.isPrimaryActionEnabled(.copyAPIAddress, canStart: false, isBusy: false))
        #expect(StudioPresentation.isPrimaryActionEnabled(.adoptUnownedServer, canStart: false, isBusy: false))
        #expect(!StudioPresentation.isPrimaryActionEnabled(.busy, canStart: true, isBusy: true))
        #expect(!StudioPresentation.isPrimaryActionEnabled(.adoptUnownedServer, canStart: true, isBusy: true))
    }

    @Test
    func apiAddressIsTheClientEndpointAndNeverTheChatPage() throws {
        let context = try makeContext("wiring-api")
        defer { context.cleanUp() }

        let address = StudioPresentation.apiAddress(for: context.config)
        #expect(address == "http://127.0.0.1:8080/v1")
        #expect(address != context.config.chatURL.absoluteString)
    }

    // MARK: - Supervision

    @Test
    func supervisionNoticeReportsRetryingAndPausedStates() {
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 0,
                isAutoRestartWanted: true
            ) == .none
        )

        // The backoff schedule is 5s, 15s, 30s, 45s, 60s.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 1,
                isAutoRestartWanted: true
            ) == .retrying(failures: 1, retryAfterSeconds: 5)
        )
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 4,
                isAutoRestartWanted: true
            ) == .retrying(failures: 4, retryAfterSeconds: 45)
        )

        // The budget is exhausted, so supervision gave up and the user must
        // start the service by hand.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: AutoRestartSupervision.maximumConsecutiveFailures,
                isAutoRestartWanted: false
            ) == .paused(failures: 5)
        )
        // Even if the intent flag lingers, the budget wins.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: AutoRestartSupervision.maximumConsecutiveFailures,
                isAutoRestartWanted: true
            ) == .paused(failures: 5)
        )
        // Failures with no standing intent are also a paused state, never a
        // promise that a retry is coming.
        #expect(
            StudioPresentation.supervisionNotice(
                consecutiveFailures: 2,
                isAutoRestartWanted: false
            ) == .paused(failures: 2)
        )
    }

    // MARK: - Hardware preflight

    @Test
    @MainActor
    func hardwarePreflightBlocksIntelMacsBeforeDownloading() throws {
        let context = try makeContext("wiring-hardware-block")
        defer { context.cleanUp() }

        let controller = context.makeController(
            hardware: HardwareRequirements(
                architecture: "x86_64",
                physicalMemoryBytes: 32 * 1_073_741_824
            )
        )

        #expect(!controller.canInstallModel)
        let message = try #require(controller.hardwareIssueMessage)
        #expect(
            StudioPresentation.hardwarePreflight(
                assessment: controller.hardwareAssessment,
                message: message
            ) == .blocker(message)
        )
    }

    @Test
    @MainActor
    func hardwarePreflightWarnsWithoutBlocking() throws {
        let context = try makeContext("wiring-hardware-warning")
        defer { context.cleanUp() }

        let controller = context.makeController(
            hardware: HardwareRequirements(
                architecture: "arm64",
                physicalMemoryBytes: 20 * 1_073_741_824
            )
        )

        #expect(controller.canInstallModel)
        let message = try #require(controller.hardwareIssueMessage)
        #expect(
            StudioPresentation.hardwarePreflight(
                assessment: controller.hardwareAssessment,
                message: message
            ) == .warning(message)
        )
    }

    @Test
    @MainActor
    func hardwarePreflightIsSilentOnASupportedMac() throws {
        let context = try makeContext("wiring-hardware-ok")
        defer { context.cleanUp() }

        let controller = context.makeController()
        #expect(controller.canInstallModel)
        #expect(controller.hardwareIssueMessage == nil)
        #expect(
            StudioPresentation.hardwarePreflight(
                assessment: controller.hardwareAssessment,
                message: controller.hardwareIssueMessage
            ) == .none
        )
    }

    // MARK: - Installation verification

    @Test
    func needsRepairCoversEveryUnusableArtifactState() {
        #expect(!ArtifactVerification.verified.needsRepair)
        // Runtime archives are validated structurally, which is a pass.
        #expect(!ArtifactVerification.notDigestVerifiable.needsRepair)
        #expect(ArtifactVerification.missing.needsRepair)
        #expect(ArtifactVerification.checksumMismatch.needsRepair)
        #expect(
            ArtifactVerification.sizeMismatch(expected: 10, actual: 4).needsRepair
        )
    }

    @Test
    func damagedComponentsAreReportedInCatalogOrder() {
        let results: [InstallationComponent: ArtifactVerification] = [
            .model: .checksumMismatch,
            .runtime: .notDigestVerifiable,
            .projector: .missing,
            .adapter: .verified,
        ]

        // Catalog order is runtime, model, projector, adapter; the runtime's
        // structural pass and the adapter's digest pass are both excluded.
        #expect(StudioPresentation.componentsNeedingRepair(in: results) == [.model, .projector])
        #expect(StudioPresentation.componentsNeedingRepair(in: [:]).isEmpty)
        #expect(
            StudioPresentation.componentsNeedingRepair(
                in: [.runtime: .verified, .adapter: .notDigestVerifiable]
            ).isEmpty
        )
    }

    // MARK: - Helpers

    @MainActor
    private func primaryAction(
        for controller: ServiceController,
        status: ServiceStatus
    ) -> StudioPrimaryAction {
        StudioPresentation.primaryAction(
            status: status,
            isBusy: controller.isBusy,
            hasUnownedServer: controller.unownedServer != nil,
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
            hardware: HardwareRequirements = HardwareRequirements(
                architecture: "arm64",
                physicalMemoryBytes: 32 * 1_073_741_824
            ),
            healthProbe: @escaping @Sendable (URL) async -> Bool = { _ in false }
        ) -> ServiceController {
            ServiceController(
                config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
                processManager: stub,
                defaults: defaults,
                healthProbe: healthProbe,
                loginItemStatus: { .notRegistered },
                hardwareRequirements: hardware
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
}
