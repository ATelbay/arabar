import XCTest
@testable import arabar

private final class AdminFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class AdminAPIRegressionTests: XCTestCase {
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdminFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        AdminFixtureProtocol.handler = nil
        super.tearDown()
    }

    func testOpenAIUsesHourlyBucketsWithinAllowedLimitAndDoesNotDoubleCountCachedInput() async throws {
        AdminFixtureProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            // 1h buckets give the 5h window real resolution; 168 is the API maximum for 1h.
            XCTAssertEqual(items.first { $0.name == "bucket_width" }?.value, "1h")
            XCTAssertEqual(items.first { $0.name == "limit" }?.value, "168")
            return Data(#"{"object":"page","has_more":false,"next_page":null,"data":[{"object":"bucket","start_time":1700000000,"end_time":1700086400,"results":[{"object":"organization.usage.completions.result","model":"gpt-test","input_tokens":100,"input_cached_tokens":40,"output_tokens":20}]}]}"#.utf8)
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let events = try await OpenAIUsageAPIReader(session: session, keyProvider: { "synthetic" }).fetchEvents()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.inputTokens, 60)
        XCTAssertEqual(event.cachedTokens, 40)
        XCTAssertEqual(event.totalTokens, 120)
    }

    func testAnthropicDecodesNestedCacheCreation() async throws {
        AdminFixtureProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "bucket_width" }?.value, "1h")
            XCTAssertEqual(items.first { $0.name == "limit" }?.value, "168")
            return Data(#"{"has_more":false,"next_page":null,"data":[{"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-09-02T00:00:00Z","results":[{"model":"claude-test","uncached_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":30},"cache_read_input_tokens":40,"output_tokens":10}]}]}"#.utf8)
        }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let events = try await AnthropicAdminAPIReader(session: session, keyProvider: { "synthetic" }).fetchEvents()
        XCTAssertEqual(events.first?.cacheCreationTokens, 50)
        XCTAssertEqual(events.first?.cacheCreation1hTokens, 30)
        XCTAssertEqual(events.first?.totalTokens, 200)
    }

    func testBothReadersRejectMissingOrRepeatedPaginationTokens() async throws {
        for nextPage in ["null", "\"same-page\""] {
            var calls = 0
            AdminFixtureProtocol.handler = { _ in
                calls += 1
                return Data("{\"object\":\"page\",\"has_more\":true,\"next_page\":\(nextPage),\"data\":[]}".utf8)
            }
            let session = fixtureSession()
            defer { session.invalidateAndCancel() }
            do {
                _ = try await OpenAIUsageAPIReader(session: session, keyProvider: { "synthetic" }).fetchEvents()
                XCTFail("Incomplete pagination must not silently return partial data")
            } catch OpenAIUsageAPIError.parsingFailed { }
            XCTAssertLessThanOrEqual(calls, 2)
            calls = 0
            do {
                _ = try await AnthropicAdminAPIReader(session: session, keyProvider: { "synthetic" }).fetchEvents()
                XCTFail("Incomplete pagination must not silently return partial data")
            } catch AnthropicAdminAPIError.parsingFailed { }
            XCTAssertLessThanOrEqual(calls, 2)
        }
    }
}
