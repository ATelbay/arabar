import Foundation
import XCTest
@testable import arabar

final class AccountQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGeminiResolvesClientConfigurationFromInstalledSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oauth2.js")
        try "const OAUTH_CLIENT_ID = 'fixture-id'; const OAUTH_CLIENT_SECRET = 'fixture-secret';".write(to: file, atomically: true, encoding: .utf8)
        let client = try GeminiOAuthClient.load(credentials: [:], candidateFiles: [file])
        XCTAssertEqual(client.id, "fixture-id")
        XCTAssertEqual(client.secret, "fixture-secret")
        XCTAssertThrowsError(try GeminiOAuthClient.load(credentials: [:], candidateFiles: []))
        XCTAssertNil(GeminiOAuthClient.parse(source: "const unrelated = 'value';"))
    }

    func testDisconnectedAccountsDiscardCachedQuotaButTransientFailuresKeepTTL() {
        for error in [AccountQuotaError.disabled, .missingKey, .missingGeminiLogin, .unauthorized, .noQuota] {
            XCTAssertTrue(error.invalidatesSnapshot)
        }
        XCTAssertFalse(AccountQuotaError.http(503).invalidatesSnapshot)
        XCTAssertFalse(AccountQuotaError.invalidResponse.invalidatesSnapshot)
    }

    func testGeminiUsesRemainingFractionAndPreservesModelBuckets() throws {
        let snapshot = try parse(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.25,"resetTime":"2030-01-01T00:00:00Z"},{"modelId":"gemini-flash","remainingFraction":0.9}]}"#, .gemini)
        XCTAssertEqual(snapshot.windows.map(\.label), ["gemini-pro", "gemini-flash"])
        XCTAssertEqual(snapshot.remainingFraction(now: now), 0.25)
        XCTAssertNotNil(snapshot.windows[0].resetAt)
    }

    func testKimiWeeklyOnlyDoesNotInventFiveHourWindow() throws {
        let snapshot = try parse(#"{"usage":{"used":"25","limit":"100","resetTime":"2030-01-01T00:00:00.123456789Z"}}"#, .kimi)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.label, "Weekly")
        XCTAssertEqual(snapshot.remainingFraction(now: now), 0.75)
        XCTAssertNotNil(snapshot.windows.first?.resetAt)
    }

    func testKimiParsesRollingWindowAndClampsExhaustedQuota() throws {
        let snapshot = try parse(#"{"usage":{"used":"120","limit":"100"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"40"}}]}"#, .kimi)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Weekly", "5h"])
        XCTAssertEqual(snapshot.windows.map(\.remainingFraction), [0, 0.4])
    }

    func testGLMConvertsPercentUsedAndKeepsDistinctQuotas() throws {
        let snapshot = try parse(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":1.5,"nextResetTime":1893456000000},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":65},{"type":"TIME_LIMIT","percentage":80}]}}"#, .glm)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5h", "1w", "Monthly tools"])
        XCTAssertEqual(snapshot.windows[0].remainingFraction, 0.985, accuracy: 0.00001)
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(snapshot.remainingFraction(now: now) ?? -1, 0.2, accuracy: 0.00001)
    }

    func testMissingMalformedOrZeroLimitDoesNotBecomeFullQuota() {
        let fixtures: [(Provider, String)] = [
            (.gemini, #"{"buckets":[{"remainingAmount":"100"}]}"#),
            (.gemini, #"{"buckets":[{"remainingFraction":true},{"remainingFraction":-1},{"remainingFraction":2}]}"#),
            (.kimi, #"{"usage":{"limit":"100"}}"#),
            (.kimi, #"{"usage":{"limit":"0","used":"0"}}"#),
            (.kimi, #"{"usage":{"limit":"100","used":false}}"#),
            (.glm, #"{"data":{"limits":[{"type":"TOKENS_LIMIT"}]}}"#),
            (.glm, #"{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":-1}]}}"#),
            (.glm, #"{"success":false,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":0}]}}"#)
        ]
        for (provider, payload) in fixtures {
            XCTAssertThrowsError(try parse(payload, provider), "\(provider): \(payload)")
        }
    }

    func testGLMApplicationLevelAuthErrorIsRejected() {
        XCTAssertThrowsError(try parse(#"{"code":401,"success":false}"#, .glm)) { error in
            guard case AccountQuotaError.unauthorized = error else { return XCTFail("Wrong error") }
        }
    }

    func testQuotaExpiresAtTTLOrResetAndDoesNotSwitchToLessRestrictedBucket() {
        let snapshot = AccountQuotaSnapshot(provider: .gemini, generatedAt: now, windows: [
            .init(id: "pro", label: "Pro", remainingFraction: 0.1, resetAt: now.addingTimeInterval(60)),
            .init(id: "flash", label: "Flash", remainingFraction: 0.9, resetAt: nil)
        ])
        XCTAssertEqual(snapshot.remainingFraction(now: now), 0.1)
        XCTAssertNil(snapshot.remainingFraction(now: now.addingTimeInterval(60)))
        let noReset = AccountQuotaSnapshot(provider: .kimi, generatedAt: now, windows: [
            .init(id: "weekly", label: "Weekly", remainingFraction: 0, resetAt: nil)
        ])
        XCTAssertEqual(noReset.remainingFraction(now: now.addingTimeInterval(1_800)), 0)
        XCTAssertNil(noReset.remainingFraction(now: now.addingTimeInterval(1_801)))
    }

    func testDisabledConfigurationDoesNotReadCredentialsOrMakeRequests() async {
        let reader = AccountQuotaReader(session: makeSession { _ in
            XCTFail("Disabled provider must not send a request")
            return (500, "{}")
        })
        do {
            _ = try await reader.fetch(configuration: .init(provider: .gemini, enabled: false, region: "global", project: "", revision: 0))
            XCTFail("Expected disabled error")
        } catch {
            guard case AccountQuotaError.disabled = error else { return XCTFail("Wrong error") }
        }
    }

    func testKimiAndGLMUseCorrectHostsAndAuthentication() async throws {
        let reader = AccountQuotaReader(session: makeSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.host == "api.kimi.ai" {
                XCTAssertEqual(request.url?.path, "/coding/v1/usages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                return (200, #"{"usage":{"used":"1","limit":"10"}}"#)
            }
            XCTAssertEqual(request.url?.host, "open.bigmodel.cn")
            XCTAssertEqual(request.url?.path, "/api/monitor/usage/quota/limit")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-key")
            return (200, #"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":30}]}}"#)
        })
        _ = try await reader.fetchKeyQuota(provider: .kimi, key: "test-key", region: "global")
        _ = try await reader.fetchKeyQuota(provider: .glm, key: "test-key", region: "china")
    }

    func testUnauthorizedHTTPResponseDoesNotParseQuota() async {
        let reader = AccountQuotaReader(session: makeSession { _ in (401, #"{"usage":{"used":0,"limit":100}}"#) })
        do {
            _ = try await reader.fetchKeyQuota(provider: .kimi, key: "test-key", region: "china")
            XCTFail("Expected rejected credentials")
        } catch {
            guard case AccountQuotaError.unauthorized = error else { return XCTFail("Wrong error") }
        }
    }

    func testGeminiRefreshesExpiredTokenAndDiscoversProjectWithoutInference() async throws {
        let reader = AccountQuotaReader(session: makeSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = Self.body(request)
            switch request.url?.host {
            case "oauth2.googleapis.com":
                XCTAssertEqual(request.url?.path, "/token")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("refresh_token=test%2Brefresh%26token"))
                return (200, #"{"access_token":"fresh-token","expires_in":3600}"#)
            case "cloudcode-pa.googleapis.com":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
                if request.url?.path == "/v1internal:loadCodeAssist" {
                    return (200, #"{"cloudaicompanionProject":"test-project"}"#)
                }
                XCTAssertEqual(request.url?.path, "/v1internal:retrieveUserQuota")
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(json?["project"] as? String, "test-project")
                return (200, #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.8}]}"#)
            default:
                XCTFail("Unexpected credential destination")
                return (500, "{}")
            }
        })
        let credentials = Data(#"{"access_token":"old-token","refresh_token":"test+refresh&token","expiry_date":1,"client_id":"test-client","client_secret":"test-client-secret"}"#.utf8)
        let snapshot = try await reader.fetchGemini(credentials: credentials, project: "")
        XCTAssertEqual(snapshot.windows.first?.remainingFraction, 0.8)
    }

    private func parse(_ payload: String, _ provider: Provider) throws -> AccountQuotaSnapshot {
        try AccountQuotaReader.parse(data: Data(payload.utf8), provider: provider, now: now)
    }

    private func makeSession(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> URLSession {
        QuotaURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class QuotaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, payload) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
