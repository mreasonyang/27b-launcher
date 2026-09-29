import Foundation

enum InstallationKind: Sendable, Equatable {
    case file
    case runtimeArchive(releaseMarker: String)
}
