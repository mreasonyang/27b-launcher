import Foundation

struct InstallationProgress: Sendable, Equatable {
    let component: InstallationComponent
    let phase: InstallationPhase
    let isResuming: Bool
    let componentCompletedBytes: Int64
    let componentTotalBytes: Int64
    let overallCompletedBytes: Int64
    let overallTotalBytes: Int64
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?

    var fractionCompleted: Double {
        guard overallTotalBytes > 0 else { return 0 }
        return min(max(Double(overallCompletedBytes) / Double(overallTotalBytes), 0), 1)
    }
}
