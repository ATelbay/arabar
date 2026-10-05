import Foundation
import XCTest
@testable import arabar

final class AccountQuotaRefreshTests: XCTestCase {
    private let quota = #"{"buckets":[{"remainingFraction":0.8}]}"#

    func testConcurrentExpiredCredentialsShareOneRefresh() async throws {
        let server = QuotaRefreshServer { request, _ in
            if request.url?.host == "oauth2.googleapis.com" {
                return .init(payload: #"{"access_token":"fresh-token","expires_in":3600}"#, delay: 0.1)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
            return .init(payload: self.quota)
        }
        let reader = AccountQuotaReader(session: session(server))
        let credentials = try credentials(expired: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await reader.fetchGemini(credentials: credentials, project: "fixture") }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(server.refreshCount, 1)
    }

    func testLateUnauthorizedResponseReusesAlreadyRefreshedToken() async throws {
        let server = QuotaRefreshServer { request, number in
            if request.url?.host == "oauth2.googleapis.com" {
                return .init(payload: #"{"access_token":"fresh-token","expires_in":3600}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                return .init(status: 401, payload: "{}", delay: number == 1 ? 0.05 : 0.2)
            }
            return .init(payload: self.quota)
        }
        let reader = AccountQuotaReader(session: session(server))
        let credentials = try credentials(expired: false)
        async let first = reader.fetchGemini(credentials: credentials, project: "fixture")
        async let second = reader.fetchGemini(credentials: credentials, project: "fixture")
        _ = try await (first, second)
        XCTAssertEqual(server.refreshCount, 1)
    }

    func testFailedRefreshDoesNotPoisonFutureAttempts() async throws {
        let server = QuotaRefreshServer { request, number in
            if request.url?.host == "oauth2.googleapis.com" {
                if number == 1 { return .init(status: 400, payload: #"{"error":"invalid_grant"}"#) }
                return .init(payload: #"{"access_token":"fresh-token","expires_in":3600}"#)
            }
            return .init(payload: self.quota)
        }
        let reader = AccountQuotaReader(session: session(server))
        let credentials = try credentials(expired: true)
        do {
            _ = try await reader.fetchGemini(credentials: credentials, project: "fixture")
            XCTFail("Expected expired login")
        } catch {
            guard case AccountQuotaError.unauthorized = error else { return XCTFail("Unexpected error: \(error)") }
        }
        _ = try await reader.fetchGemini(credentials: credentials, project: "fixture")
        XCTAssertEqual(server.refreshCount, 2)
    }

    func testMalformedLoginInvalidatesPreviousQuotaWithoutMakingRequests() async {
        let reader = AccountQuotaReader(session: session(QuotaRefreshServer { _, _ in
            XCTFail("Malformed credentials must not be sent to a provider")
            return .init(payload: "{}")
        }))
        do {
            _ = try await reader.fetchGemini(credentials: Data("{incomplete".utf8), project: "fixture")
            XCTFail("Expected missing login")
        } catch {
            guard case AccountQuotaError.missingGeminiLogin = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue((error as? AccountQuotaError)?.invalidatesSnapshot == true)
        }
    }

    func testLoginChangeDuringRequestDiscardsPreviousAccountsQuota() async throws {
        let login = QuotaFixtureLogin(try credentials(expired: false))
        let reader = AccountQuotaReader(session: session(QuotaRefreshServer { _, _ in
            login.replace(with: Data(#"{"access_token":"different-account"}"#.utf8))
            return .init(payload: self.quota)
        }), readGeminiCredentials: { login.read() })
        do {
            _ = try await reader.fetch(configuration: .init(provider: .gemini, enabled: true, region: "global", project: "fixture", revision: 0))
            XCTFail("Quota from previous login must not be published")
        } catch {
            guard case AccountQuotaError.credentialsChanged = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue((error as? AccountQuotaError)?.invalidatesSnapshot == true)
        }
    }

    func testUnchangedLoginPublishesQuota() async throws {
        let credentials = try credentials(expired: false)
        let reader = AccountQuotaReader(session: session(QuotaRefreshServer { _, _ in
            .init(payload: self.quota)
        }), readGeminiCredentials: { credentials })
        let snapshot = try await reader.fetch(configuration: .init(provider: .gemini, enabled: true, region: "global", project: "fixture", revision: 0))
        XCTAssertEqual(snapshot.windows.first?.remainingFraction, 0.8)
    }

    private func credentials(expired: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "access_token": "old-token", "refresh_token": "fixture-refresh",
            "client_id": "fixture-client", "client_secret": "fixture-secret",
            "expiry_date": expired ? 1 : Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        ])
    }

    private func session(_ server: QuotaRefreshServer) -> URLSession {
        QuotaRefreshProtocol.server = server
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaRefreshProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class QuotaRefreshServer {
    struct Response {
        var status = 200
        var payload: String
        var delay: TimeInterval = 0
    }
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let handler: (URLRequest, Int) -> Response

    init(handler: @escaping (URLRequest, Int) -> Response) { self.handler = handler }

    var refreshCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts["oauth2.googleapis.com", default: 0]
    }

    func respond(to request: URLRequest) -> Response {
        lock.lock()
        let host = request.url!.host!
        counts[host, default: 0] += 1
        let count = counts[host]!
        lock.unlock()
        return handler(request, count)
    }
}

private final class QuotaRefreshProtocol: URLProtocol {
    static var server: QuotaRefreshServer!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.server.respond(to: request)
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) {
            let http = HTTPURLResponse(url: self.request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(response.payload.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class QuotaFixtureLogin {
    private let lock = NSLock()
    private var credentials: Data
    init(_ credentials: Data) { self.credentials = credentials }
    func replace(with credentials: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }
    func read() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }
}
