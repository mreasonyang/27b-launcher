import Foundation

struct ServerLaunchOptions: Sendable, Equatable {
    let ablationEnabled: Bool
    let ablationStrength: AblationStrength
    let bindMode: ServerBindMode
}
