import Foundation

struct InstallationVolumeSpace: Sendable, Equatable, Identifiable {
    let volume: URL
    let requiredBytes: Int64
    let availableBytes: Int64

    var id: URL { volume }
    var isSufficient: Bool { availableBytes >= requiredBytes }
}
