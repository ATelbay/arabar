import XCTest
@testable import arabar

final class ClaudeCookiesReaderParsingTests: XCTestCase {
    func testZeroUtilizationIsAuthoritativeHundredPercentLeft() {
        let window = ClaudeCookiesReader.parseWindowSnapshot(
            from: ["utilization": 0, "resets_at": "2026-05-18T12:00:00Z"],
            durationHours: 168
        )

        XCTAssertEqual(window.percentSource, .authoritative)
        XCTAssertEqual(window.percentUsed, 0)
        XCTAssertNotNil(window.resetAt)
    }

    func testFractionalUtilizationParsesAsPercent() {
        let window = ClaudeCookiesReader.parseWindowSnapshot(
            from: ["utilization": 0.5],
            durationHours: 168
        )

        XCTAssertEqual(window.percentSource, .authoritative)
        XCTAssertEqual(window.percentUsed, 0.005)
    }

    func testMissingUtilizationIsUnknownButKeepsReset() {
        let window = ClaudeCookiesReader.parseWindowSnapshot(
            from: ["resets_at": "2026-05-18T12:00:00Z"],
            durationHours: 168
        )

        XCTAssertEqual(window.percentSource, .unknown)
        XCTAssertNil(window.percentUsed)
        XCTAssertNotNil(window.resetAt)
    }

    func testMissingWindowIsUnknown() {
        let window = ClaudeCookiesReader.parseWindowSnapshot(from: nil, durationHours: 168)

        XCTAssertEqual(window.percentSource, .unknown)
        XCTAssertNil(window.percentUsed)
        XCTAssertNil(window.resetAt)
    }

    func testBrowserActiveOrganizationWinsOverFirstChatOrganization() {
        let orgs: [[String: Any]] = [
            ["uuid": "11111111-1111-1111-1111-111111111111", "capabilities": ["chat"]],
            ["uuid": "22222222-2222-2222-2222-222222222222", "capabilities": ["chat", "claude_max"]],
        ]
        XCTAssertEqual(
            ClaudeCookiesReader.selectOrganization(from: orgs, preferredOrgId: "22222222-2222-2222-2222-222222222222"),
            "22222222-2222-2222-2222-222222222222"
        )
        // A stale cookie for an org the session no longer belongs to falls back to the old rule.
        XCTAssertEqual(
            ClaudeCookiesReader.selectOrganization(from: orgs, preferredOrgId: "33333333-3333-3333-3333-333333333333"),
            "11111111-1111-1111-1111-111111111111"
        )
        XCTAssertEqual(
            ClaudeCookiesReader.selectOrganization(from: orgs, preferredOrgId: nil),
            "11111111-1111-1111-1111-111111111111"
        )
    }
}
