import Testing
@testable import Launcher27B

@Suite
struct LlamaMetricsParserTests {
    @Test
    func parsesTokenCountersAndOperationalGauges() throws {
        let payload = """
        # HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.
        llamacpp:prompt_tokens_total 1234
        llamacpp:prompt_tokens_cached_total 34
        llamacpp:tokens_predicted_total 567
        llamacpp:prompt_tokens_seconds 48.25
        llamacpp:predicted_tokens_seconds 21.75
        llamacpp:requests_processing 2
        llamacpp:requests_deferred 1
        llamacpp:n_tokens_max 4096
        """

        let usage = try LlamaMetricsParser().parse(payload)

        #expect(usage.processedPromptTokens == 1_234)
        #expect(usage.cachedPromptTokens == 34)
        #expect(usage.promptTokens == 1_268)
        #expect(usage.generatedTokens == 567)
        #expect(usage.totalTokens == 1_835)
        #expect(usage.promptTokensPerSecond == 48.25)
        #expect(usage.generatedTokensPerSecond == 21.75)
        #expect(usage.activeRequests == 2)
        #expect(usage.deferredRequests == 1)
        #expect(usage.maximumContextTokens == 4_096)
    }

    @Test
    func rejectsIncompleteOrLabeledCountersFromAnUnexpectedSchema() throws {
        #expect(throws: LlamaMetricsError.missingTokenCounters) {
            try LlamaMetricsParser().parse("llamacpp:prompt_tokens_total{model=\"27B\"} 80\nllamacpp:tokens_predicted_total 20")
        }
    }

    @Test
    func rejectsPayloadWithoutTokenCounters() throws {
        #expect(throws: LlamaMetricsError.missingTokenCounters) {
            try LlamaMetricsParser().parse("llamacpp:requests_processing 0")
        }
    }

    /// The derived sums must not trap: two individually-legal counters can overflow
    /// `Int` when added, and `StudioTelemetryGrid` reads `totalTokens` on every
    /// refresh, so a crafted `/metrics` body killed the launcher with SIGTRAP.
    @Test
    func extremeCountersSaturateInsteadOfTrapping() throws {
        let nearMaximum = 9_000_000_000_000_000_000

        let snapshot = TokenUsageSnapshot(
            processedPromptTokens: nearMaximum,
            cachedPromptTokens: nearMaximum,
            generatedTokens: nearMaximum,
            promptTokensPerSecond: 0,
            generatedTokensPerSecond: 0,
            activeRequests: 0,
            deferredRequests: 0,
            maximumContextTokens: 0
        )
        #expect(snapshot.promptTokens == Int.max)
        #expect(snapshot.totalTokens == Int.max)

        // The same shape, through the parser the launcher actually uses.
        let payload = """
        llamacpp:prompt_tokens_total 9000000000000000000
        llamacpp:prompt_tokens_cached_total 9000000000000000000
        llamacpp:tokens_predicted_total 9000000000000000000
        llamacpp:prompt_tokens_seconds 0
        llamacpp:predicted_tokens_seconds 0
        llamacpp:requests_processing 0
        llamacpp:requests_deferred 0
        llamacpp:n_tokens_max 0
        """

        #expect(throws: LlamaMetricsError.invalidResponse) { try LlamaMetricsParser().parse(payload) }
    }

    @Test
    func saturatingSumKeepsOrdinaryAndNegativeResultsExact() {
        #expect(TokenUsageSnapshot.saturatingSum(1_234, 34) == 1_268)
        #expect(TokenUsageSnapshot.saturatingSum(Int.max, 0) == Int.max)
        #expect(TokenUsageSnapshot.saturatingSum(Int.min, -1) == Int.min)
        #expect(TokenUsageSnapshot.saturatingSum(Int.max, -1) == Int.max - 1)
    }
}
