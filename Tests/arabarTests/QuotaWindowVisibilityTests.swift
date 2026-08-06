import XCTest
@testable import arabar

final class QuotaWindowVisibilityTests: XCTestCase {
    func testWeeklyOnlySnapshotHidesMissingSessionWindow() {
        let session = window(durationHours: 5, source: .unknown)
        let weekly = window(durationHours: 168, percentUsed: 0.29, source: .authoritative)

        XCTAssertFalse(QuotaWindowVisibility.shouldShow(session, sibling: weekly))
        XCTAssertTrue(QuotaWindowVisibility.shouldShow(weekly, sibling: session))
    }

    func testBothAuthoritativeWindowsRemainVisible() {
        let session = window(durationHours: 5, percentUsed: 0.16, source: .authoritative)
        let weekly = window(durationHours: 168, percentUsed: 0.42, source: .authoritative)

        XCTAssertTrue(QuotaWindowVisibility.shouldShow(session, sibling: weekly))
        XCTAssertTrue(QuotaWindowVisibility.shouldShow(weekly, sibling: session))
    }

    func testJSONLOnlyUnknownWindowsRemainVisible() {
        let session = window(durationHours: 5, tokensUsed: 100, source: .unknown)
        let weekly = window(durationHours: 168, tokensUsed: 500, source: .unknown)

        XCTAssertTrue(QuotaWindowVisibility.shouldShow(session, sibling: weekly))
        XCTAssertTrue(QuotaWindowVisibility.shouldShow(weekly, sibling: session))
    }

    func testWindowWithMergedJSONLUsageRemainsVisible() {
        let session = window(durationHours: 5, tokensUsed: 100, source: .unknown)
        let weekly = window(durationHours: 168, percentUsed: 0.29, source: .authoritative)

        XCTAssertTrue(QuotaWindowVisibility.shouldShow(session, sibling: weekly))
    }

    private func window(
        durationHours: Int,
        tokensUsed: Int = 0,
        percentUsed: Double? = nil,
        source: PercentSource
    ) -> WindowSnapshot {
        WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: tokensUsed,
            costUSD: 0,
            percentUsed: percentUsed,
            resetAt: percentUsed == nil ? nil : Date(timeIntervalSince1970: 1_800_000_000),
            percentSource: source
        )
    }
}
