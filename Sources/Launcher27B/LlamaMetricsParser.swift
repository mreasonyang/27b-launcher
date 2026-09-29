import Foundation

/// Parses the metrics emitted by the catalog's pinned runtime. Missing or invalid
/// observations are unavailable, never invented zeroes.
struct LlamaMetricsParser: Sendable {
    func parse(_ payload: String) throws -> TokenUsageSnapshot {
        let required: Set<String> = ["prompt_tokens_total", "prompt_tokens_cached_total", "tokens_predicted_total",
            "prompt_tokens_seconds", "predicted_tokens_seconds", "requests_processing", "requests_deferred", "n_tokens_max"]
        var metrics: [String: Double] = [:]
        for rawLine in payload.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, first.hasPrefix("llamacpp:") else { continue }
            let name = String(first.dropFirst("llamacpp:".count))
            guard required.contains(name) else { continue }
            guard fields.count == 2, let value = Double(fields[1]), value.isFinite, value >= 0,
                  metrics[name] == nil else { throw LlamaMetricsError.invalidResponse }
            metrics[name] = value
        }
        guard required.isSubset(of: Set(metrics.keys)) else { throw LlamaMetricsError.missingTokenCounters }
        func value(_ name: String) throws -> Double {
            guard let value = metrics[name] else { throw LlamaMetricsError.missingTokenCounters }
            return value
        }
        func count(_ name: String) throws -> Int {
            let number = try value(name)
            guard number < Double(Int.max), number.rounded(.down) == number else { throw LlamaMetricsError.invalidResponse }
            return Int(number)
        }
        let prompt = try count("prompt_tokens_total")
        let cached = try count("prompt_tokens_cached_total")
        let generated = try count("tokens_predicted_total")
        let (promptSum, promptOverflow) = prompt.addingReportingOverflow(cached)
        guard !promptOverflow, !promptSum.addingReportingOverflow(generated).overflow else { throw LlamaMetricsError.invalidResponse }
        return try TokenUsageSnapshot(processedPromptTokens: prompt, cachedPromptTokens: cached, generatedTokens: generated,
            promptTokensPerSecond: value("prompt_tokens_seconds"), generatedTokensPerSecond: value("predicted_tokens_seconds"),
            activeRequests: count("requests_processing"), deferredRequests: count("requests_deferred"), maximumContextTokens: count("n_tokens_max"))
    }
}

enum LlamaMetricsError: Error, Equatable, AppLocalizableError {
    case invalidResponse
    case requestFailed(Int)
    case missingTokenCounters
    @MainActor func localizedDescription(using preferences: AppPreferences) -> String {
        preferences.localized("统计不可用：服务未返回完整有效的监控数据。")
    }
}
