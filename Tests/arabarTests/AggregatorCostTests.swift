import XCTest
@testable import arabar

final class AggregatorCostTests: XCTestCase {

    private func event(
        provider: Provider,
        model: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0
    ) -> UsageEvent {
        UsageEvent(
            timestamp: Date(),
            provider: provider,
            model: model,
            sessionId: "s1",
            messageId: UUID().uuidString,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens
        )
    }

    // Sonnet 4.6 inputPerMTok = 3.00 → 1M input = $3.00
    func testSonnet46_1MInputTokens() {
        let e = event(provider: .claude, model: "claude-sonnet-4-6", inputTokens: 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: e), 3.00, accuracy: 0.0001)
    }

    // Opus 4.7 outputPerMTok = 25.00 → 1M output = $25.00
    func testOpus47_1MOutputTokens() {
        let e = event(provider: .claude, model: "claude-opus-4-7", outputTokens: 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: e), 25.00, accuracy: 0.0001)
    }

    // Unknown model → 0.0 (no crash)
    func testUnknownModel_returnsZero() {
        let e = event(provider: .claude, model: "claude-unknown-999")
        XCTAssertEqual(Aggregator.cost(for: e), 0.0, accuracy: 0.0001)
    }

    // Sonnet 4.6 cacheWrite5mPerMTok = 3.75 → 1M cacheCreationTokens = $3.75
    func testSonnet46_1MCacheCreationTokens_uses5mTier() {
        let e = event(provider: .claude, model: "claude-sonnet-4-6", cacheCreationTokens: 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: e), 3.75, accuracy: 0.0001)
    }

    // gpt-5-4 outputPerMTok = 15.00; reasoning billed at output rate → 1M reasoning = $15.00
    func testCodexGpt54_1MReasoningTokens_billedAtOutputRate() {
        let e = event(provider: .codex, model: "gpt-5-4", reasoningTokens: 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: e), 15.00, accuracy: 0.0001)
    }
}
