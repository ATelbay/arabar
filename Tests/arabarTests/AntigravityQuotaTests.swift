import XCTest
@testable import arabar

final class AntigravityQuotaTests: XCTestCase {
    override func tearDown() {
        AntigravityURLProtocol.handler = nil
        super.tearDown()
    }

    func testDecodesGoKeyringBase64TokenWithNanosecondExpiry() throws {
        let json = #"{"access_token":"ya29.a","token_type":"Bearer","refresh_token":"1//r","expiry":"2030-01-02T03:04:05.123456789+05:00"}"#
        let raw = "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
        let credentials = try XCTUnwrap(AntigravityAuth.decode(raw))
        XCTAssertEqual(credentials.accessToken, "ya29.a")
        XCTAssertEqual(credentials.refreshToken, "1//r")
        XCTAssertEqual(try XCTUnwrap(credentials.expiry).timeIntervalSince1970, 1_893_535_445, accuracy: 1)
        XCTAssertNil(AntigravityAuth.decode("go-keyring-base64:not-base64!"))
        XCTAssertNil(AntigravityAuth.decode(#"{"unrelated":true}"#))
    }

    func testExtractsEveryClientIdSecretCombinationFromBinary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // Assembled at runtime so the fixture never looks like a real credential to
        // secret scanners; the values are synthetic.
        let clientId = "123456789-" + String(repeating: "x", count: 24) + ".apps." + "googleusercontent.com"
        let secretPrefix = "GOC" + "SPX-"
        let secretA = secretPrefix + String(repeating: "a", count: 28)
        let secretB = secretPrefix + String(repeating: "b", count: 28)
        var bytes = Data([0, 1, 2])
        bytes += Data(clientId.utf8) + Data([0])
        bytes += Data(secretA.utf8) + Data([0, 9])
        bytes += Data(secretB.utf8) + Data([0])
        try bytes.write(to: url)
        let clients = AntigravityAuth.oauthClients(in: url)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(Set(clients.map(\.id)), [clientId])
        XCTAssertEqual(clients.map(\.secret).sorted(), [secretA, secretB])
    }

    func testParsesModelQuotaMapAndTreatsOmittedFractionAsExhausted() throws {
        let data = Data(#"""
        {"models":{
          "gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.4,"resetTime":"2030-01-01T00:00:00Z"}},
          "claude-sonnet":{"displayName":"Claude Sonnet","quotaInfo":{"resetTime":"2030-01-01T00:00:00Z"}},
          "no-quota-model":{"displayName":"Hidden"}
        }}
        """#.utf8)
        let windows = try AccountQuotaReader.parseAntigravityModels(data: data)
        XCTAssertEqual(windows.map(\.label), ["Claude Sonnet", "Gemini 3 Pro"])
        XCTAssertEqual(windows.map(\.remainingFraction), [0, 0.4])
        XCTAssertNotNil(windows.first?.resetAt)
    }

    func testRefreshesWithWorkingClientPairAndQueriesAgyProject() async throws {
        var tokenAttempts: [String] = []
        var quotaRequest: URLRequest?
        AntigravityURLProtocol.handler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let body = String(data: request.bodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
                tokenAttempts.append(body)
                return body.contains("client_secret=good")
                    ? (200, #"{"access_token":"fresh","expires_in":3600}"#)
                    : (401, #"{"error":"invalid_client"}"#)
            }
            quotaRequest = request
            return (200, #"{"models":{"m":{"displayName":"Model","quotaInfo":{"remainingFraction":1}}}}"#)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AntigravityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let expired = AntigravityCredentials(accessToken: "stale", refreshToken: "1//r",
                                             expiry: Date().addingTimeInterval(-10), client: nil)
        let reader = AccountQuotaReader(
            session: session,
            readAntigravity: { expired },
            antigravityClients: { [GeminiOAuthClient(id: "id", secret: "bad"), GeminiOAuthClient(id: "id", secret: "good")] },
            antigravityProject: { "agy-project" }
        )
        var quota = AccountQuotaConfiguration(provider: .gemini, enabled: true, region: "global", project: "", revision: 0)
        quota.source = GeminiQuotaSource.antigravity
        let snapshot = try await reader.fetch(configuration: quota)

        XCTAssertEqual(snapshot.windows.map(\.label), ["Model"])
        XCTAssertEqual(tokenAttempts.count, 2)
        XCTAssertEqual(quotaRequest?.url?.absoluteString, "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        XCTAssertEqual(quotaRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let body = try XCTUnwrap(quotaRequest?.bodyStreamData ?? quotaRequest?.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["project"] as? String, "agy-project")
    }

    func testMissingAgySignInIsReported() async {
        let reader = AccountQuotaReader(readAntigravity: { nil })
        var quota = AccountQuotaConfiguration(provider: .gemini, enabled: true, region: "global", project: "", revision: 0)
        quota.source = GeminiQuotaSource.antigravity
        do {
            _ = try await reader.fetch(configuration: quota)
            XCTFail("expected missingAntigravityLogin")
        } catch AccountQuotaError.missingAntigravityLogin {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private extension URLRequest {
    /// URLProtocol receives POST bodies as a stream.
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class AntigravityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
