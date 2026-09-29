import Foundation

struct InstallationArtifact: Identifiable, Sendable, Equatable {
    let component: InstallationComponent
    let downloadURL: URL
    let destinationURL: URL
    let expectedByteCount: Int64
    let expectedSHA256: String
    let kind: InstallationKind

    var id: InstallationComponent { component }
}
