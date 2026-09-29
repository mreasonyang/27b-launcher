import Foundation

enum InstallationComponent: String, CaseIterable, Identifiable, Sendable {
    case runtime
    case model
    case projector
    case adapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime: "Prism 推理运行时"
        case .model: "Bonsai 2 · 27B 模型"
        case .projector: "视觉投影文件"
        case .adapter: "OrcaBonsai 模块"
        }
    }

    var detail: String {
        switch self {
        case .runtime: "运行低比特模型所需的本地 llama.cpp 组件"
        case .model: "用于本地推理的 PQ2_0 模型权重"
        case .projector: "让模型能够理解图片和截图"
        case .adapter: "可调节拒答倾向的本地 LoRA 文件"
        }
    }

    var symbolName: String {
        switch self {
        case .runtime: "gearshape.2"
        case .model: "brain"
        case .projector: "photo"
        case .adapter: "slider.horizontal.3"
        }
    }
}
