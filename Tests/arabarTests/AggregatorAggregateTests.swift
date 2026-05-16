import XCTest
@testable import arabar

final class AggregatorAggregateTests: XCTestCase {

    private let aggregator = Aggregator()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func event(
        provider: Provider = .claude,
        messageId: String? = "msg-1",
        hoursAgo: Double = 1,
        inputTokens: Int = 100
    ) -> UsageEvent {
        UsageEvent(
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            provider: provider,
            model: "claude-sonnet-4-6",
            sessionId: "s1",
            messageId: messageId,
            inputTokens: inputTokens
        )
    }

    // Two events with identical messageId → deduped to one; tokensUsed counted once
    func testDeduplication_sameMessageId_countedOnce() {
        let e1 = event(messageId: "dup-msg", inputTokens: 500)
        let e2 = event(messageId: "dup-msg", inputTokens: 500)
        let snapshots = aggregator.aggregate(events: [e1, e2], now: now)
        let session = snapshots[.claude]!.sessionWindow
        XCTAssertEqual(session.tokensUsed, 500)
    }

    // Event 6h ago + event 4h ago; 5h session window → only 4h-old event counted
    func testWindowFilter_onlyRecentEventCounted() {
        let old = event(messageId: "old", hoursAgo: 6, inputTokens: 1000)
        let recent = event(messageId: "new", hoursAgo: 4, inputTokens: 200)
        let snapshots = aggregator.aggregate(events: [old, recent], now: now)
        let session = snapshots[.claude]!.sessionWindow
        XCTAssertEqual(session.tokensUsed, 200)
    }

    // Empty events → tokensUsed == 0, percentUsed == nil
    func testEmptyEvents_zeroTokens_noPercent() {
        let snapshots = aggregator.aggregate(events: [], now: now)
        let session = snapshots[.claude]!.sessionWindow
        XCTAssertEqual(session.tokensUsed, 0)
        XCTAssertNil(session.percentUsed)
    }

    // resetAt = firstEventInWindow.timestamp + windowDuration (5h = 18000s)
    func testResetAt_equalsFirstEventPlusWindowDuration() {
        let t = now.addingTimeInterval(-3600)  // 1h ago, well within 5h window
        let e = UsageEvent(
            timestamp: t,
            provider: .claude,
            model: "claude-sonnet-4-6",
            sessionId: "s1",
            messageId: "msg-a",
            inputTokens: 10
        )
        let snapshots = aggregator.aggregate(events: [e], now: now)
        let session = snapshots[.claude]!.sessionWindow
        let expected = t.addingTimeInterval(5 * 3600)
        XCTAssertEqual(session.resetAt, expected)
    }

    // Events with messageId == nil are NOT deduplicated (each kept separately — by design)
    func testNilMessageId_notDeduplicated_eachKeptSeparately() {
        let e1 = event(messageId: nil, hoursAgo: 1, inputTokens: 300)
        let e2 = event(messageId: nil, hoursAgo: 1, inputTokens: 300)
        let snapshots = aggregator.aggregate(events: [e1, e2], now: now)
        let session = snapshots[.claude]!.sessionWindow
        XCTAssertEqual(session.tokensUsed, 600)
    }
}
