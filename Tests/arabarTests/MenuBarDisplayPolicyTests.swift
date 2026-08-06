import XCTest
@testable import arabar

final class MenuBarDisplayPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWeeklyOnlySnapshotUsesWeeklyWindow() throws {
        let snapshot = usageSnapshot(
            session: window(durationHours: 5, source: .unknown),
            weekly: window(durationHours: 168, percentUsed: 0.29, source: .authoritative)
        )

        let selected = try XCTUnwrap(MenuBarDisplayPolicy.preferredWindow(in: snapshot, now: now))
        XCTAssertEqual(selected.durationHours, 168)
        XCTAssertEqual(try XCTUnwrap(selected.percentUsed), 0.29, accuracy: 0.000_001)
    }

    func testSessionWindowRemainsPreferredWhenBothAreUsable() throws {
        let snapshot = usageSnapshot(
            session: window(durationHours: 5, percentUsed: 0.16, source: .authoritative),
            weekly: window(durationHours: 168, percentUsed: 0.42, source: .authoritative)
        )

        let selected = try XCTUnwrap(MenuBarDisplayPolicy.preferredWindow(in: snapshot, now: now))
        XCTAssertEqual(selected.durationHours, 5)
    }

    func testExpiredSessionFallsBackToUsableWeeklyWindow() throws {
        let snapshot = usageSnapshot(
            session: window(
                durationHours: 5,
                percentUsed: 0.16,
                resetAt: now.addingTimeInterval(-1),
                source: .authoritative
            ),
            weekly: window(durationHours: 168, percentUsed: 0.42, source: .authoritative)
        )

        let selected = try XCTUnwrap(MenuBarDisplayPolicy.preferredWindow(in: snapshot, now: now))
        XCTAssertEqual(selected.durationHours, 168)
    }

    func testSnapshotWithoutAuthoritativePercentHasNoPreferredWindow() {
        let snapshot = usageSnapshot(
            session: window(durationHours: 5, source: .unknown),
            weekly: window(durationHours: 168, source: .unknown)
        )

        XCTAssertNil(MenuBarDisplayPolicy.preferredWindow(in: snapshot, now: now))
    }

    private func usageSnapshot(session: WindowSnapshot, weekly: WindowSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            generatedAt: now,
            sessionWindow: session,
            weeklyWindow: weekly,
            totalEventsInPeriod: 0
        )
    }

    private func window(
        durationHours: Int,
        percentUsed: Double? = nil,
        resetAt: Date? = nil,
        source: PercentSource
    ) -> WindowSnapshot {
        WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: 0,
            costUSD: 0,
            percentUsed: percentUsed,
            resetAt: resetAt ?? (percentUsed == nil ? nil : now.addingTimeInterval(3600)),
            percentSource: source
        )
    }
}
