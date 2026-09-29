import Foundation

enum ArtifactDownloadState: Sendable, Equatable {
    case downloading(isResuming: Bool)
    case waitingForNetwork(retryAttempt: Int, retryAfterSeconds: Int)
}

struct ArtifactDownloadUpdate: Sendable, Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
    let state: ArtifactDownloadState
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?
}
