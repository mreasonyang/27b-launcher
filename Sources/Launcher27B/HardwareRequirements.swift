import Foundation

/// Static, UI-agnostic preflight checks for the 27B Q2 model.
///
/// The bundled Prism runtime is published for `macos-arm64` only, so an Intel Mac
/// can download the whole payload and still be unable to run the server. The model
/// itself (7.2 GB of weights) plus a 32K context KV cache also needs far more memory
/// than an 8 GB Mac has. Callers should surface `assessment` *before* starting a
/// multi-hour download. This type deliberately has no UI: a later phase wires it in.
struct HardwareRequirements: Sendable, Equatable {
    /// The catalog downloads `…-bin-macos-arm64.tar.gz`; other architectures cannot run it.
    static let requiredArchitecture = "arm64"

    /// Resident memory the shipped 27B artifact actually needs with `-ngl 99 -c 32768`:
    ///
    ///  * weights — the ~7.2 GB PQ2_0 file is mmapped and becomes fully resident once
    ///    every layer is offloaded (`-ngl 99`), so it cannot be paged out under load;
    ///  * 32K-context KV cache — 2 (K and V) x layers x kv-heads x head-dim x 32768
    ///    x 2 bytes, which for a 27B-class model with grouped-query attention is
    ///    roughly 3-6 GB;
    ///  * llama.cpp compute/scratch buffers and the Metal working set — ~1-2 GB.
    ///
    /// That is ~13-15 GB before macOS itself (~4-6 GB on Apple silicon, plus whatever
    /// the user is running). The threshold below is derived from this budget rather
    /// than from a round number; the arithmetic is why a 16 GiB Mac can only run the
    /// model by swapping.
    static let estimatedModelWorkingSetBytes: UInt64 = 13 * 1_073_741_824

    /// Hard floor: at the working set plus a minimal OS there is nothing left, so
    /// 8 GiB machines (the next Apple-silicon configuration below 16 GiB) are refused
    /// before spending the 7.9 GB download.
    static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1_073_741_824

    /// Comfortable threshold: the working set, macOS, and real headroom for the
    /// user's other applications. Machines between the floor and this value stay
    /// installable but warn — refusing a 16 or 24 GiB Mac would wrongly refuse a
    /// machine that *can* run the model (per the product rule "when unsure, warn
    /// rather than block"), while passing it silently would hide that it swaps.
    static let recommendedPhysicalMemoryBytes: UInt64 = 32 * 1_073_741_824

    let architecture: String
    let physicalMemoryBytes: UInt64

    init(architecture: String, physicalMemoryBytes: UInt64) {
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// Snapshot of the machine this process is running on.
    static func current() -> HardwareRequirements {
        HardwareRequirements(
            architecture: currentArchitecture,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    static var currentArchitecture: String {
        var systemInfo = utsname()
        _ = uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { machine in
                String(cString: machine)
            }
        }
    }

    /// Preflight verdict for this machine.
    ///
    /// The arch check is deliberately independent of the memory budget: the bundled
    /// runtime is arm64-only, so an Intel Mac cannot run the model at any memory size
    /// and must be refused before the download. On supported hardware, 16-31 GiB
    /// yields `.warning` rather than a refusal — those machines can run the model but
    /// swap at 32K context, and refusing a runnable machine is worse than warning
    /// about it. Only 8 GiB-class machines (below ``minimumPhysicalMemoryBytes``) are
    /// refused, because they cannot hold the working set plus macOS at all.
    var assessment: HardwareAssessment {
        guard architecture == Self.requiredArchitecture else {
            return .unsatisfied(.unsupportedArchitecture(current: architecture))
        }
        guard physicalMemoryBytes >= Self.minimumPhysicalMemoryBytes else {
            return .unsatisfied(
                .insufficientMemory(
                    requiredBytes: Self.minimumPhysicalMemoryBytes,
                    availableBytes: physicalMemoryBytes
                )
            )
        }
        guard physicalMemoryBytes >= Self.recommendedPhysicalMemoryBytes else {
            return .warning(
                .limitedMemory(
                    recommendedBytes: Self.recommendedPhysicalMemoryBytes,
                    availableBytes: physicalMemoryBytes
                )
            )
        }
        return .satisfied
    }

    /// `false` only when installation should be refused outright.
    var canInstall: Bool {
        if case .unsatisfied = assessment {
            return false
        }
        return true
    }
}

enum HardwareAssessment: Sendable, Equatable {
    case satisfied
    case warning(HardwareRequirementIssue)
    case unsatisfied(HardwareRequirementIssue)

    var issue: HardwareRequirementIssue? {
        switch self {
        case .satisfied:
            nil
        case let .warning(issue), let .unsatisfied(issue):
            issue
        }
    }

    var isSatisfied: Bool {
        self == .satisfied
    }
}

enum HardwareRequirementIssue: Error, Sendable, Equatable, LocalizedError, AppLocalizableError {
    case unsupportedArchitecture(current: String)
    case insufficientMemory(requiredBytes: UInt64, availableBytes: UInt64)
    case limitedMemory(recommendedBytes: UInt64, availableBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case let .unsupportedArchitecture(current):
            "这台 Mac 的处理器（\(current)）不受支持；Bonsai 2 需要 Apple 芯片（arm64）。"
        case let .insufficientMemory(required, available):
            "内存不足：运行 27B 模型至少需要 "
                + "\(required.formatted(.byteCount(style: .memory)))，"
                + "这台 Mac 只有 \(available.formatted(.byteCount(style: .memory)))。"
        case let .limitedMemory(recommended, available):
            "内存偏低：建议至少 \(recommended.formatted(.byteCount(style: .memory)))"
                + "（当前 \(available.formatted(.byteCount(style: .memory)))），长上下文时可能变慢。"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case let .unsupportedArchitecture(current):
            preferences.localizedFormat(
                "这台 Mac 的处理器（%@）不受支持；Bonsai 2 需要 Apple 芯片（arm64）。",
                current
            )
        case let .insufficientMemory(required, available):
            preferences.localizedFormat(
                "内存不足：运行 27B 模型至少需要 %@，这台 Mac 只有 %@。",
                required.formatted(.byteCount(style: .memory)),
                available.formatted(.byteCount(style: .memory))
            )
        case let .limitedMemory(recommended, available):
            preferences.localizedFormat(
                "内存偏低：建议至少 %@（当前 %@），长上下文时可能变慢。",
                recommended.formatted(.byteCount(style: .memory)),
                available.formatted(.byteCount(style: .memory))
            )
        }
    }
}
