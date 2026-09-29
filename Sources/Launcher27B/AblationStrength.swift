import Foundation

enum AblationStrength: String, CaseIterable, Identifiable, Sendable {
    case partial = "0.5"
    case moderate = "0.7"
    case strong = "0.9"
    case exact = "1.0"
    case aggressive = "2.0"

    static let defaultValue: AblationStrength = .aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .partial: "0.5× · 温和"
        case .moderate: "0.7× · 平衡"
        case .strong: "0.9× · 强力"
        case .exact: "1.0× · 完整效果"
        case .aggressive: "2.0× · 默认"
        }
    }

    var explanation: String {
        switch self {
        case .partial: "轻微减少拒答，尽量保持原始回答风格。"
        case .moderate: "兼顾减少拒答和回答稳定性，适合日常使用。"
        case .strong: "明显减少拒答，输出变化会更明显。"
        case .exact: "完整应用模块的标准效果。"
        case .aggressive: "默认以 2.0× 强度应用模块，可根据回答效果调整。"
        }
    }
}
