import XCTest
@testable import arabar

final class SubscriptionSnapshotPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func snapshot(at date: Date, tokens: Int, percent: Double?) -> UsageSnapshot {
        func window(_ hours: Int) -> WindowSnapshot {
            WindowSnapshot(durationHours: hours, tokensUsed: tokens, costUSD: Double(tokens) / 10,
                           percentUsed: percent, resetAt: percent == nil ? nil : now.addingTimeInterval(600),
                           percentSource: percent == nil ? .unknown : .authoritative)
        }
        return UsageSnapshot(provider: .claude, generatedAt: date, sessionWindow: window(5),
                             weeklyWindow: window(168), totalEventsInPeriod: tokens == 0 ? 0 : 2)
    }

    func testRemoteFailureKeepsQuotaTimestampButUpdatesLocalUsage() throws {
        let cached = snapshot(at: now.addingTimeInterval(-180), tokens: 10, percent: 0.7)
        let local = snapshot(at: now, tokens: 90, percent: nil)
        let result = try XCTUnwrap(SubscriptionSnapshotPolicy.preferUseful(new: local, current: cached, now: now))
        XCTAssertEqual(result.generatedAt, cached.generatedAt)
        XCTAssertEqual(result.sessionWindow.percentUsed, 0.7)
        XCTAssertEqual(result.sessionWindow.tokensUsed, 90)
        XCTAssertEqual(result.weeklyWindow.costUSD, 9)
        XCTAssertEqual(SnapshotFreshnessPolicy.freshness(of: result, now: now), .stale)
    }

    func testLocalUsageCanRollToZeroDuringRemoteFailure() throws {
        let cached = snapshot(at: now.addingTimeInterval(-180), tokens: 10, percent: 0.7)
        let local = snapshot(at: now, tokens: 0, percent: nil)
        let result = try XCTUnwrap(SubscriptionSnapshotPolicy.preferUseful(new: local, current: cached, now: now))
        XCTAssertEqual(result.sessionWindow.tokensUsed, 0)
        XCTAssertEqual(result.weeklyWindow.costUSD, 0)
        XCTAssertEqual(result.totalEventsInPeriod, 0)
        XCTAssertEqual(result.sessionWindow.percentUsed, 0.7)
    }

    func testExpiredQuotaDoesNotMaskLocalFallback() {
        let cached = snapshot(at: now.addingTimeInterval(-1_801), tokens: 10, percent: 0.7)
        let local = snapshot(at: now, tokens: 90, percent: nil)
        XCTAssertEqual(SubscriptionSnapshotPolicy.preferUseful(new: local, current: cached, now: now), local)
    }

    func testOneFailedLocalReaderDoesNotDiscardOtherReadersEvents() {
        let event = UsageEvent(timestamp: now, provider: .claude, model: "fixture", sessionId: "test", inputTokens: 12)
        for failingFirst in [true, false] {
            let successful: () throws -> [UsageEvent] = { [event] }
            let failed: () throws -> [UsageEvent] = { throw CocoaError(.fileReadNoPermission) }
            let result = AppViewModel.readLocalSources(failingFirst ? [failed, successful] : [successful, failed])
            XCTAssertEqual(result.0, [event])
            XCTAssertEqual(result.1.count, 1)
        }
    }
}
