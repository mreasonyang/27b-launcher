import Foundation

enum ServerBindMode: String, CaseIterable, Identifiable, Sendable {
    case loopback
    case allInterfaces

    var id: Self { self }

    var hostArgument: String {
        switch self {
        case .loopback:
            "127.0.0.1"
        case .allInterfaces:
            "0.0.0.0"
        }
    }

    var titleKey: String {
        switch self {
        case .loopback:
            "仅本机"
        case .allInterfaces:
            "所有网络接口"
        }
    }

    var detailKey: String {
        switch self {
        case .loopback:
            "127.0.0.1 · 只接受本机连接"
        case .allInterfaces:
            "0.0.0.0 · 接受所有网络接口的连接"
        }
    }
}
