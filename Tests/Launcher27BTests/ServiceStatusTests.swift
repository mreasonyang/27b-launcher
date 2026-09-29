import Testing
@testable import Launcher27B

struct ServiceStatusTests {
    @Test(arguments: [
        (false, false, ServiceStatus.stopped),
        (true, false, ServiceStatus.starting),
        (true, true, ServiceStatus.running),
        (false, true, ServiceStatus.external)
    ])
    func resolvesObservedState(
        isManaged: Bool,
        isHealthy: Bool,
        expected: ServiceStatus
    ) {
        #expect(
            ServiceStatus.resolve(
                isLoaded: isManaged,
                isHealthy: isHealthy,
                operation: nil
            ) == expected
        )
    }

    @Test
    func operationTakesPriorityOverObservedState() {
        #expect(
            ServiceStatus.resolve(
                isLoaded: true,
                isHealthy: true,
                operation: .restarting
            ) == .restarting
        )
    }
}
