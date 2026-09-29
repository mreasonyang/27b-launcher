import Foundation

enum ModelStorageMigrationOutcome: Sendable, Equatable {
    case success(String)
    case cancelled(String)
    case failure(String)

    var message: String {
        switch self {
        case let .success(message), let .cancelled(message), let .failure(message): message
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .cancelled: "pause.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}

/// A non-fatal condition worth telling the user about after an otherwise
/// successful migration.
enum ModelStorageMigrationNotice: Sendable, Equatable {
    /// The old model location could not be removed, so the disk still holds
    /// two copies of the models.
    case sourceLocationRetained(byteCount: Int64)

}

enum ModelStorageMigrationPhase: Sendable, Equatable {
    case copying
    case verifying
    case switching

    var title: String {
        switch self {
        case .copying: "正在复制模型"
        case .verifying: "正在校验模型"
        case .switching: "正在切换模型位置"
        }
    }
}

struct ModelStorageMigrationProgress: Sendable, Equatable {
    let phase: ModelStorageMigrationPhase
    let stageCompletedBytes: Int64
    let stageTotalBytes: Int64
    let overallCompletedBytes: Int64
    let overallTotalBytes: Int64
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?

    var fractionCompleted: Double {
        guard overallTotalBytes > 0 else { return 0 }
        return min(max(Double(overallCompletedBytes) / Double(overallTotalBytes), 0), 1)
    }
}

struct ModelStorageProgressSampler {
    private let startedAt = ContinuousClock.now
    private var lastEmission = ContinuousClock.now

    mutating func update(
        phase: ModelStorageMigrationPhase,
        stageCompleted: Int64,
        stageTotal: Int64,
        overallCompleted: Int64,
        overallTotal: Int64,
        force: Bool = false
    ) -> ModelStorageMigrationProgress? {
        let now = ContinuousClock.now
        guard force || lastEmission.duration(to: now) >= .milliseconds(250) else {
            return nil
        }
        lastEmission = now
        let elapsed = startedAt.duration(to: now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let speed = seconds > 0 && overallCompleted > 0
            ? Double(overallCompleted) / seconds
            : nil
        let remaining = max(overallTotal - overallCompleted, 0)
        let eta = speed.flatMap { $0 > 0 ? Double(remaining) / $0 : nil }

        return ModelStorageMigrationProgress(
            phase: phase,
            stageCompletedBytes: min(max(stageCompleted, 0), stageTotal),
            stageTotalBytes: stageTotal,
            overallCompletedBytes: min(max(overallCompleted, 0), overallTotal),
            overallTotalBytes: overallTotal,
            bytesPerSecond: speed,
            estimatedTimeRemaining: eta
        )
    }
}
