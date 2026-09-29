import Foundation

enum InstallationStatus: Sendable, Equatable {
    case checking
    case ready
    case required
    case installing
    case failed
}
