struct TokenUsageSnapshot: Sendable, Equatable {
    let processedPromptTokens: Int
    let cachedPromptTokens: Int
    let generatedTokens: Int
    let promptTokensPerSecond: Double
    let generatedTokensPerSecond: Double
    let activeRequests: Int
    let deferredRequests: Int
    let maximumContextTokens: Int

    /// The two prompt counters added together.
    ///
    /// Every component is individually bounded at the parser boundary, but two
    /// individually-legal counters can still overflow `Int` when added, and
    /// `/metrics` is an unauthenticated local HTTP body. `StudioTelemetryGrid`
    /// reads ``totalTokens`` on every refresh, so a trapping `+` here kills the
    /// launcher: the sums saturate instead.
    var promptTokens: Int {
        Self.saturatingSum(processedPromptTokens, cachedPromptTokens)
    }

    var totalTokens: Int {
        Self.saturatingSum(promptTokens, generatedTokens)
    }

    /// `+` traps on overflow; `addingReportingOverflow` reports it instead, so
    /// the UI shows an absurd-but-sane number rather than dying.
    static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return lhs > 0 ? .max : .min
    }
}
