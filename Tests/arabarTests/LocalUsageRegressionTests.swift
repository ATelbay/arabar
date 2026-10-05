import XCTest
@testable import arabar

final class LocalUsageRegressionTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var cache: URL!
    private let now = Date()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("sessions")
        cache = directory.appendingPathComponent("cache/reader.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func claude(_ id: String, input: Int = 10, output: Int = 5) -> [String: Any] {
        ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now),
         "sessionId": "claude-session", "message": ["id": id, "model": "claude-sonnet-4-6",
            "usage": ["input_tokens": input, "output_tokens": output]]]
    }

    private func codex(_ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["type": type, "timestamp": ISO8601DateFormatter().string(from: now), "payload": payload]
    }

    private func tokenCount(total: Int, turnID: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 40,
                                  "output_tokens": 30, "reasoning_output_tokens": 10],
            "total_token_usage": ["total_tokens": total]]]
        payload["turn_id"] = turnID
        return codex("event_msg", payload)
    }

    func testClaudeRetriesPartialLineAndReadsAfterTruncation() throws {
        let file = root.appendingPathComponent("session.jsonl")
        let first = try line(claude("first-long-message-id"))
        let second = try line(claude("second"))
        try (first + second.prefix(second.count / 2)).write(to: file)
        let reader = ClaudeUsageReader(rootDirs: [root], cacheFile: cache)
        XCTAssertEqual(try reader.fetchNewEvents().map(\.messageId), ["first-long-message-id"])
        try append(second.dropFirst(second.count / 2), to: file)
        XCTAssertEqual(try reader.fetchNewEvents().map(\.messageId), ["second"])
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)
        try line(claude("replacement")).write(to: file)
        XCTAssertEqual(try reader.fetchNewEvents().map(\.messageId), ["replacement"])
    }

    func testClaudeFinalUsageReplacesEarlierPartialUsageAcrossReads() throws {
        let file = root.appendingPathComponent("session.jsonl")
        try line(claude("streamed", output: 1)).write(to: file)
        let reader = ClaudeUsageReader(rootDirs: [root], cacheFile: cache)
        var events = try reader.fetchNewEvents()
        try append(line(claude("streamed", output: 50)), to: file)
        events += try reader.fetchNewEvents()
        let snapshot = Aggregator().aggregate(events: events, now: now)[.claude]
        XCTAssertEqual(snapshot?.sessionWindow.tokensUsed, 60)
        XCTAssertEqual(snapshot?.totalEventsInPeriod, 1)
    }

    func testCodexFirstRunPartialWritesAndPersistedModelAndSession() throws {
        let file = root.appendingPathComponent("rollout-session.jsonl")
        let headers = try line(codex("session_meta", ["id": "actual-session", "model_provider": "openai"]))
            + line(codex("turn_context", ["model": "gpt-5.4"]))
        let usage = try line(tokenCount(total: 130))
        try (headers + usage.prefix(usage.count / 2)).write(to: file)
        let reader = CodexUsageReader(rootDirs: [root], cacheFile: cache)
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "First-run cache must be created")
        try append(usage.dropFirst(usage.count / 2), to: file)
        let resumedReader = CodexUsageReader(rootDirs: [root], cacheFile: cache)
        let event = try XCTUnwrap(resumedReader.fetchNewEvents().first)
        XCTAssertEqual(event.sessionId, "actual-session")
        XCTAssertEqual(event.model, "gpt-5.4")
        XCTAssertEqual(event.inputTokens, 60)
        XCTAssertEqual(event.outputTokens, 20)
        XCTAssertEqual(event.cachedTokens, 40)
        XCTAssertEqual(event.reasoningTokens, 10)
        XCTAssertEqual(event.totalTokens, 130)
        XCTAssertEqual(Aggregator.cost(for: event), 0.00061, accuracy: 0.0000001)
        XCTAssertTrue(try resumedReader.fetchNewEvents().isEmpty)
    }

    func testCodexPreservesMultipleCallsPerTurnButIgnoresRepeatedTotals() throws {
        let file = root.appendingPathComponent("rollout-session.jsonl")
        try (line(codex("turn_context", ["turn_id": "turn", "model": "gpt-5.4"]))
             + line(tokenCount(total: 130, turnID: "turn"))).write(to: file)
        let reader = CodexUsageReader(rootDirs: [root], cacheFile: cache)
        var events = try reader.fetchNewEvents()
        try append(line(tokenCount(total: 130, turnID: "turn"))
                   + line(tokenCount(total: 260, turnID: "turn")), to: file)
        events += try reader.fetchNewEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertNotEqual(events[0].messageId, events[1].messageId)
        let snapshot = Aggregator().aggregate(events: events, now: now)[.codex]
        XCTAssertEqual(snapshot?.sessionWindow.tokensUsed, 260)
        // Moving a rollout into archived_sessions must not double count it.
        XCTAssertEqual(try reader.rebuildAll().map(\.messageId), events.map(\.messageId))
    }

    func testCodexRecoversAfterTruncationAndCacheWriteFailure() throws {
        let file = root.appendingPathComponent("rollout-session.jsonl")
        let longHeader = try line(codex("session_meta", ["id": String(repeating: "x", count: 400)]))
        try (longHeader + line(tokenCount(total: 130))).write(to: file)
        let blockingFile = directory.appendingPathComponent("blocked")
        try Data().write(to: blockingFile)
        let reader = CodexUsageReader(rootDirs: [root], cacheFile: blockingFile.appendingPathComponent("cache.json"))
        XCTAssertThrowsError(try reader.fetchNewEvents())
        try FileManager.default.removeItem(at: blockingFile)
        XCTAssertEqual(try reader.fetchNewEvents().count, 1, "Failed cache persistence must not consume events")
        try line(tokenCount(total: 260)).write(to: file)
        XCTAssertEqual(try reader.fetchNewEvents().count, 1)
    }

    func testPiClaudeCacheReadUsesAnthropicPricingWithoutRecordedCost() throws {
        let file = root.appendingPathComponent("pi-session.jsonl")
        try line(["type": "message", "id": "pi-entry", "timestamp": ISO8601DateFormatter().string(from: now),
                  "message": ["role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-6",
                              "usage": ["input": 100, "output": 20, "cacheRead": 1_000_000]]]).write(to: file)
        let reader = PiUsageReader(targetProvider: .claude, rootDirs: [root], cacheFile: cache)
        let event = try XCTUnwrap(reader.fetchNewEvents().first)
        XCTAssertEqual(event.cacheReadTokens, 1_000_000)
        XCTAssertEqual(event.cachedTokens, 0)
        XCTAssertEqual(Aggregator.cost(for: event), 0.3006, accuracy: 0.0000001)
    }

    func testPiRetriesPartialLinesAndDoesNotLoseEventsAfterCacheFailure() throws {
        let file = root.appendingPathComponent("pi-session.jsonl")
        let data = try line(["type": "message", "id": "pi-entry", "timestamp": ISO8601DateFormatter().string(from: now),
                             "message": ["role": "assistant", "provider": "openai", "model": "gpt-5.4",
                                         "usage": ["input": 100]]])
        try data.prefix(data.count / 2).write(to: file)
        let blockingFile = directory.appendingPathComponent("blocked")
        let reader = PiUsageReader(targetProvider: .codex, rootDirs: [root],
                                   cacheFile: blockingFile.appendingPathComponent("cache.json"))
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)
        try FileManager.default.removeItem(at: blockingFile)
        try Data().write(to: blockingFile)
        try append(data.dropFirst(data.count / 2), to: file)
        XCTAssertThrowsError(try reader.fetchNewEvents())
        try FileManager.default.removeItem(at: blockingFile)
        XCTAssertEqual(try reader.fetchNewEvents().count, 1)
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)
    }

    func testUsageEventStillDecodesBufferWithoutCacheTTLField() throws {
        let event = UsageEvent(timestamp: now, provider: .claude, model: "claude-sonnet-4-6",
                               sessionId: "legacy", inputTokens: 10)
        let data = try JSONEncoder().encode(event)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cacheCreation1hTokens")
        object.removeValue(forKey: "recordedCostUSD")
        let legacy = try JSONDecoder().decode(UsageEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.totalTokens, 10)
        XCTAssertNil(legacy.cacheCreation1hTokens)
    }

    func testDatedClaudeModelsAndDottedOpenAIModelsResolvePricing() {
        for model in ["claude-sonnet-4-5", "claude-sonnet-4-5-20250929"] {
            let event = UsageEvent(timestamp: now, provider: .claude, model: model,
                                   sessionId: "s", inputTokens: 1_000_000)
            XCTAssertEqual(Aggregator.cost(for: event), 3)
        }
        let event = UsageEvent(timestamp: now, provider: .codex, model: "gpt-5.4",
                               sessionId: "s", inputTokens: 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: event), 2.5)
    }

    func testClaudeOneHourCacheWritesUseOneHourRateWithoutExtraTokens() throws {
        let file = root.appendingPathComponent("session.jsonl")
        try line(["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now),
                  "message": ["id": "ttl", "model": "claude-sonnet-4-6",
                              "usage": ["cache_creation_input_tokens": 1_000_000,
                                        "cache_creation": ["ephemeral_1h_input_tokens": 400_000]]]]).write(to: file)
        let reader = ClaudeUsageReader(rootDirs: [root], cacheFile: cache)
        let event = try XCTUnwrap(reader.fetchNewEvents().first)
        XCTAssertEqual(event.totalTokens, 1_000_000)
        XCTAssertEqual(Aggregator.cost(for: event), 4.65, accuracy: 0.000001)
    }

    func testCodexInvalidTimestampDoesNotBecomeUsageToday() throws {
        let file = root.appendingPathComponent("rollout-session.jsonl")
        var record = tokenCount(total: 130)
        record["timestamp"] = "broken"
        try line(record).write(to: file)
        let reader = CodexUsageReader(rootDirs: [root], cacheFile: cache)
        XCTAssertTrue(try reader.fetchNewEvents().isEmpty)
    }

    func testFutureEventsDoNotIncreaseCurrentWindowUsage() {
        let event = UsageEvent(timestamp: now.addingTimeInterval(3600), provider: .claude,
                               model: "claude-sonnet-4-6", sessionId: "s", inputTokens: 100)
        XCTAssertEqual(Aggregator().aggregate(events: [event], now: now)[.claude]?.sessionWindow.tokensUsed, 0)
    }
}
