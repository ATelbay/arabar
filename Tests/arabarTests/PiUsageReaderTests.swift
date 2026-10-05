import Foundation
import XCTest
@testable import arabar

final class PiUsageReaderTests: XCTestCase {
    func testParsesOpenAIAssistantUsageAndUsesRecordedCost() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try writeJSONLines([
            [
                "type": "session",
                "version": 3,
                "id": "session-123",
                "timestamp": "2026-08-06T12:00:00.000Z",
                "cwd": "/tmp/project"
            ],
            [
                "type": "message",
                "id": "entry-1",
                "parentId": NSNull(),
                "timestamp": "2026-08-06T12:01:00.000Z",
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.6-sol",
                    "usage": usage(
                        input: 100,
                        output: 20,
                        cacheRead: 30,
                        cacheWrite: 10,
                        reasoning: 7,
                        cost: 0.42
                    )
                ]
            ]
        ], to: fixture.sessionFile)

        let reader = PiUsageReader(
            targetProvider: .codex,
            rootDirs: [fixture.sessionsDirectory],
            cacheFile: fixture.cacheFile
        )
        let events = try reader.rebuildAll()

        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.model, "gpt-5.6-sol")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.messageId, "pi:session-123:entry-1")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 20)
        XCTAssertEqual(event.cachedTokens, 30)
        XCTAssertEqual(event.cacheCreationTokens, 10)
        XCTAssertEqual(event.reasoningTokens, 0, "Pi reasoning is already included in output")
        XCTAssertEqual(Aggregator.cost(for: event), 0.42, accuracy: 0.000_001)

        let snapshot = Aggregator().aggregate(
            events: events,
            now: try XCTUnwrap(Self.isoDate("2026-08-06T12:02:00.000Z"))
        )
        XCTAssertEqual(snapshot[.codex]?.sessionWindow.tokensUsed, 160)
        XCTAssertEqual(snapshot[.codex]?.sessionWindow.costUSD ?? -1, 0.42, accuracy: 0.000_001)
    }

    func testIncrementalReadDoesNotRepeatEventsAndFiltersProvider() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try writeJSONLines([
            [
                "type": "session",
                "version": 3,
                "id": "session-456",
                "timestamp": "2026-08-06T12:00:00.000Z",
                "cwd": "/tmp/project"
            ],
            assistantEntry(
                id: "openai-1",
                timestamp: "2026-08-06T12:01:00.000Z",
                provider: "openai-codex",
                model: "gpt-5.5",
                input: 10
            )
        ], to: fixture.sessionFile)

        let reader = PiUsageReader(
            targetProvider: .codex,
            rootDirs: [fixture.sessionsDirectory],
            cacheFile: fixture.cacheFile
        )

        XCTAssertEqual(try reader.fetchNewEvents().map(\.messageId), ["pi:session-456:openai-1"])
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)

        try appendJSONLines([
            assistantEntry(
                id: "claude-1",
                timestamp: "2026-08-06T12:02:00.000Z",
                provider: "anthropic",
                model: "claude-sonnet-4-6",
                input: 20
            ),
            assistantEntry(
                id: "openai-2",
                timestamp: "2026-08-06T12:03:00.000Z",
                provider: "openai-codex",
                model: "gpt-5.6-sol",
                input: 30
            )
        ], to: fixture.sessionFile)

        let newEvents = try reader.fetchNewEvents()
        XCTAssertEqual(newEvents.map(\.messageId), ["pi:session-456:openai-2"])
        XCTAssertEqual(newEvents.first?.inputTokens, 30)
    }

    private struct Fixture {
        let directory: URL
        let sessionsDirectory: URL
        let sessionFile: URL
        let cacheFile: URL
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiUsageReaderTests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDirectory = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )
        return Fixture(
            directory: directory,
            sessionsDirectory: sessionsDirectory,
            sessionFile: sessionsDirectory.appendingPathComponent("session.jsonl"),
            cacheFile: directory.appendingPathComponent("cache.json")
        )
    }

    private func usage(
        input: Int,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        cost: Double = 0
    ) -> [String: Any] {
        [
            "input": input,
            "output": output,
            "cacheRead": cacheRead,
            "cacheWrite": cacheWrite,
            "reasoning": reasoning,
            "totalTokens": input + output + cacheRead + cacheWrite,
            "cost": ["total": cost]
        ]
    }

    private func assistantEntry(
        id: String,
        timestamp: String,
        provider: String,
        model: String,
        input: Int
    ) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "parentId": NSNull(),
            "timestamp": timestamp,
            "message": [
                "role": "assistant",
                "provider": provider,
                "model": model,
                "usage": usage(input: input)
            ]
        ]
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        try encodedJSONLines(objects).write(to: url, options: .atomic)
    }

    private func appendJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encodedJSONLines(objects))
    }

    private func encodedJSONLines(_ objects: [[String: Any]]) throws -> Data {
        var data = Data()
        for object in objects {
            data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
