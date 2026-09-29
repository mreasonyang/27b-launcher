import Foundation

enum ServiceOperation: Sendable, Equatable {
    case starting
    case stopping
    case restarting
}

enum ServiceStatus: Sendable, Equatable {
    case checking
    case stopped
    case starting
    case stopping
    case restarting
    case running
    case external

    var title: String {
        switch self {
        case .checking: "正在检查"
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .stopping: "正在停止"
        case .restarting: "正在重启"
        case .running: "运行中"
        case .external: "由其他方式运行"
        }
    }

    var detail: String {
        switch self {
        case .checking: "正在读取本机服务状态"
        case .stopped: "模型未占用内存"
        case .starting: "首次加载通常需要数秒"
        case .stopping: "正在卸载模型"
        case .restarting: "正在重新加载模型"
        case .running: "Bonsai 2 已可用"
        case .external: "端口可用，但服务不是由本启动器管理"
        }
    }

    static func resolve(
        isLoaded: Bool,
        isHealthy: Bool,
        operation: ServiceOperation?
    ) -> ServiceStatus {
        if let operation {
            switch operation {
            case .starting: return .starting
            case .stopping: return .stopping
            case .restarting: return .restarting
            }
        }

        if isLoaded && isHealthy { return .running }
        if isLoaded { return .starting }
        if isHealthy { return .external }
        return .stopped
    }
}
