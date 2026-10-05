import XCTest
@testable import arabar

final class OpenAIUsageSnapshotMapperTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testWeeklyOnlyPrimaryWindowMapsToWeeklyRow() throws {
        let resetAt = 1_775_468_693
        let snapshot = try decode("""
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": {
              "used_percent": 30,
              "reset_at": \(resetAt),
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          }
        }
        """)

        XCTAssertEqual(snapshot.generatedAt, generatedAt)
        XCTAssertEqual(snapshot.sessionWindow.durationHours, 5)
        XCTAssertNil(snapshot.sessionWindow.percentUsed)
        XCTAssertNil(snapshot.sessionWindow.resetAt)

        XCTAssertEqual(snapshot.weeklyWindow.durationHours, 168)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyWindow.percentUsed), 0.30, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.weeklyWindow.resetAt, Date(timeIntervalSince1970: TimeInterval(resetAt)))
        XCTAssertEqual(snapshot.weeklyWindow.percentSource, .authoritative)
    }

    func testFractionalUsedPercentDecodesInsteadOfFailingWholeResponse() throws {
        let snapshot = try decode("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 12.5,
              "reset_at": 1766948068.5,
              "limit_window_seconds": 18000
            }
          }
        }
        """)

        XCTAssertEqual(try XCTUnwrap(snapshot.sessionWindow.percentUsed), 0.125, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.sessionWindow.percentSource, .authoritative)
    }

    func testReversedWeeklyAndSessionWindowsAreNormalizedByDuration() throws {
        let weeklyReset = 1_767_407_914
        let sessionReset = 1_766_948_068
        let snapshot = try decode("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 43,
              "reset_at": \(weeklyReset),
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": 17,
              "reset_at": \(sessionReset),
              "limit_window_seconds": 18000
            }
          }
        }
        """)

        XCTAssertEqual(snapshot.sessionWindow.durationHours, 5)
        XCTAssertEqual(try XCTUnwrap(snapshot.sessionWindow.percentUsed), 0.17, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.sessionWindow.resetAt, Date(timeIntervalSince1970: TimeInterval(sessionReset)))

        XCTAssertEqual(snapshot.weeklyWindow.durationHours, 168)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyWindow.percentUsed), 0.43, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.weeklyWindow.resetAt, Date(timeIntervalSince1970: TimeInterval(weeklyReset)))
    }

    func testStandardSessionAndWeeklyOrderIsPreserved() throws {
        let snapshot = try decode("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            }
          }
        }
        """)

        XCTAssertEqual(snapshot.sessionWindow.durationHours, 5)
        XCTAssertEqual(try XCTUnwrap(snapshot.sessionWindow.percentUsed), 0.22, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.weeklyWindow.durationHours, 168)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyWindow.percentUsed), 0.43, accuracy: 0.000_001)
    }

    func testFullyUsedWindowRemainsExhaustedAndPercentIsClamped() throws {
        for percent in [0, 1, 100, 120, -5] {
            let snapshot = try decode("""
            {"rate_limit":{"primary_window":{"used_percent":\(percent),"reset_at":1700000000,"limit_window_seconds":18000}}}
            """)
            XCTAssertEqual(snapshot.sessionWindow.percentUsed, Double(min(100, max(0, percent))) / 100)
        }
    }

    private func decode(_ json: String) throws -> UsageSnapshot {
        try OpenAIUsageSnapshotMapper.decodeSnapshot(Data(json.utf8), generatedAt: generatedAt)
    }
}
