import XCTest
@testable import arabar

final class SnapshotFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func window(
        source: PercentSource = .authoritative,
        percentUsed: Double? = 0.25,
        resetAt: Date? = nil,
        durationHours: Int = 5
    ) -> WindowSnapshot {
        WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: 123,
            costUSD: 1.23,
            percentUsed: percentUsed,
            resetAt: resetAt,
            percentSource: source
        )
    }

    private func snapshot(generatedAt: Date, session: WindowSnapshot, weekly: WindowSnapshot? = nil) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            generatedAt: generatedAt,
            sessionWindow: session,
            weeklyWindow: weekly ?? window(durationHours: 168),
            totalEventsInPeriod: 1
        )
    }

    func testGeneratedAtBoundaries() {
        XCTAssertEqual(
            SnapshotFreshnessPolicy.freshness(generatedAt: now.addingTimeInterval(-120), now: now),
            .fresh
        )
        XCTAssertEqual(
            SnapshotFreshnessPolicy.freshness(generatedAt: now.addingTimeInterval(-121), now: now),
            .stale
        )
        XCTAssertEqual(
            SnapshotFreshnessPolicy.freshness(generatedAt: now.addingTimeInterval(-1_800), now: now),
            .stale
        )
        XCTAssertEqual(
            SnapshotFreshnessPolicy.freshness(generatedAt: now.addingTimeInterval(-1_801), now: now),
            .expired
        )
    }

    func testResetAtPassedExpiresAuthoritativeWindowEvenWhenRecent() {
        let win = window(resetAt: now.addingTimeInterval(-1))
        XCTAssertEqual(
            SnapshotFreshnessPolicy.freshness(of: win, generatedAt: now, now: now),
            .expired
        )
        XCTAssertTrue(
            SnapshotFreshnessPolicy.shouldSuppressPercent(for: win, generatedAt: now, now: now)
        )
    }

    func testResetAtPassedSuppressesOnlyThatWindow() {
        let expiredSession = window(resetAt: now.addingTimeInterval(-1), durationHours: 5)
        let freshWeekly = window(resetAt: now.addingTimeInterval(3600), durationHours: 168)
        let snap = snapshot(generatedAt: now, session: expiredSession, weekly: freshWeekly)

        XCTAssertEqual(SnapshotFreshnessPolicy.freshness(of: snap, now: now), .stale)
        XCTAssertTrue(SnapshotFreshnessPolicy.shouldSuppressPercent(for: snap.sessionWindow, generatedAt: snap.generatedAt, now: now))
        XCTAssertFalse(SnapshotFreshnessPolicy.shouldSuppressPercent(for: snap.weeklyWindow, generatedAt: snap.generatedAt, now: now))
        XCTAssertTrue(SnapshotFreshnessPolicy.hasDisplayableAuthoritativeData(snap, now: now))
    }

    func testSnapshotFreshnessExpiredWhenAllAuthoritativeWindowsExpired() {
        let snap = snapshot(
            generatedAt: now,
            session: window(resetAt: now.addingTimeInterval(-1), durationHours: 5),
            weekly: window(resetAt: now.addingTimeInterval(-1), durationHours: 168)
        )

        XCTAssertEqual(SnapshotFreshnessPolicy.freshness(of: snap, now: now), .expired)
    }

    func testNonAuthoritativeSnapshotIsNotTTLExpired() {
        let oldUnknown = window(source: .unknown, percentUsed: nil)
        let snap = snapshot(
            generatedAt: now.addingTimeInterval(-86_400),
            session: oldUnknown,
            weekly: window(source: .unknown, percentUsed: nil, durationHours: 168)
        )

        XCTAssertNil(SnapshotFreshnessPolicy.freshness(of: snap, now: now))
        XCTAssertFalse(SnapshotFreshnessPolicy.isExpiredForSticky(snap, now: now))
        XCTAssertFalse(SnapshotFreshnessPolicy.shouldSuppressPercent(for: snap.sessionWindow, generatedAt: snap.generatedAt, now: now))
    }

    func testExpiredAuthoritativeSnapshotIsNotDisplayableForSticky() {
        let snap = snapshot(
            generatedAt: now.addingTimeInterval(-1_801),
            session: window(),
            weekly: window(durationHours: 168)
        )

        XCTAssertTrue(SnapshotFreshnessPolicy.isExpiredForSticky(snap, now: now))
        XCTAssertFalse(SnapshotFreshnessPolicy.hasDisplayableAuthoritativeData(snap, now: now))
    }

    func testAuthoritativeNilPercentIsNotDisplayableForSticky() {
        let snap = snapshot(
            generatedAt: now,
            session: window(percentUsed: nil),
            weekly: window(percentUsed: nil, durationHours: 168)
        )

        XCTAssertTrue(SnapshotFreshnessPolicy.hasAuthoritativeData(snap))
        XCTAssertFalse(SnapshotFreshnessPolicy.hasDisplayableAuthoritativeData(snap, now: now))
    }
}
