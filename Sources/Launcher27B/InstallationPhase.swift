import Foundation

enum InstallationPhase: Sendable, Equatable {
    case downloading
    case waitingForNetwork
    case verifying
    case copying
    case installing

    var title: String {
        switch self {
        case .downloading: "正在下载"
        case .waitingForNetwork: "网络中断，等待自动重试"
        case .verifying: "正在校验"
        case .copying: "正在复制到目标位置"
        case .installing: "正在配置"
        }
    }
}
