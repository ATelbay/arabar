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
}
