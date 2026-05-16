import XCTest
@testable import arabar

final class MakeWindowSnapshotTokensTests: XCTestCase {

    private let aggregator = Aggregator()
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func singleEvent(
        provider: Provider = .claude,
        model: String = "claude-sonnet-4-6",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0
    ) -> [UsageEvent] {
        [UsageEvent(
            timestamp: now.addingTimeInterval(-60),
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
        )]
    }

    // All 6 fields = 1000 each → tokensUsed == 6000
    func testAllSixFields_1000Each_equals6000() {
        let events = singleEvent(
            inputTokens: 1000,
            outputTokens: 1000,
            cacheReadTokens: 1000,
            cacheCreationTokens: 1000,
            cachedTokens: 1000,
            reasoningTokens: 1000
        )
        let snapshot = aggregator.aggregate(events: events, now: now)
        XCTAssertEqual(snapshot[.claude]!.sessionWindow.tokensUsed, 6000)
    }

    // Claude-only event: cachedTokens and reasoningTokens = 0 → sum of 4 fields
    func testClaudeOnlyEvent_correctSubsetSum() {
        let events = singleEvent(
            inputTokens: 500,
            outputTokens: 300,
            cacheReadTokens: 200,
            cacheCreationTokens: 100,
            cachedTokens: 0,
            reasoningTokens: 0
        )
        let snapshot = aggregator.aggregate(events: events, now: now)
        XCTAssertEqual(snapshot[.claude]!.sessionWindow.tokensUsed, 1100)
    }

    // Codex-only event: cacheReadTokens and cacheCreationTokens = 0 → sum of 4 fields
    func testCodexOnlyEvent_correctSubsetSum() {
        let events = singleEvent(
            provider: .codex,
            model: "gpt-5-4",
            inputTokens: 400,
            outputTokens: 200,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cachedTokens: 150,
            reasoningTokens: 50
        )
        let snapshot = aggregator.aggregate(events: events, now: now)
        XCTAssertEqual(snapshot[.codex]!.sessionWindow.tokensUsed, 800)
    }
}
