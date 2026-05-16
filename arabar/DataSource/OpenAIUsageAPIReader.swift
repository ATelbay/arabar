import Foundation

// MARK: - Error

enum OpenAIUsageAPIError: Error {
    case missingKey
    case httpError(Int, String)
    case parsingFailed(String)
    case disabled
}

// MARK: - DTO

private struct UsageResponse: Decodable {
    let object: String
    let data: [Bucket]
    let hasMore: Bool
    let nextPage: String?
}

private struct Bucket: Decodable {
    let object: String
    let startTime: Int
    let endTime: Int
    let results: [CompletionResult]
}

private struct CompletionResult: Decodable {
    let object: String
    let inputTokens: Int?
    let outputTokens: Int?
    let inputCachedTokens: Int?
    let inputAudioTokens: Int?       // ignored — audio billing not tracked
    let outputAudioTokens: Int?      // ignored — audio billing not tracked
    let numModelRequests: Int?
    let projectId: String?
    let userId: String?
    let apiKeyId: String?
    let model: String?
    let batch: Bool?                 // TODO: expose batch flag if UI ever needs separate bucketing
}

// MARK: - Reader

final class OpenAIUsageAPIReader {

    private let session: URLSession
    private static let baseURL = "https://api.openai.com/v1/organization/usage/completions"
    private static let maxPages = 50

    // Decoder: snake_case → camelCase, timestamps decoded as Int manually
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Returns last N days of API usage. Each daily bucket per model → one UsageEvent.
    /// Throws .missingKey if no Admin key is stored.
    func fetchEvents(lookbackDays: Int = 30) async throws -> [UsageEvent] {
        let key = try resolvedKey()

        let now = Date()
        let startTime = Int(now.addingTimeInterval(-Double(lookbackDays) * 86400).timeIntervalSince1970)
        let endTime = Int(now.timeIntervalSince1970)

        var allEvents: [UsageEvent] = []
        var pageToken: String? = nil
        var pagesRead = 0

        repeat {
            let (buckets, hasMore, nextPage) = try await fetchPage(
                key: key,
                startTime: startTime,
                endTime: endTime,
                pageToken: pageToken
            )

            for bucket in buckets {
                let date = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
                for result in bucket.results {
                    let event = UsageEvent(
                        timestamp: date,
                        provider: .codex,
                        model: result.model ?? "unknown",
                        sessionId: result.projectId ?? "default-project",
                        messageId: nil,
                        inputTokens: result.inputTokens ?? 0,
                        outputTokens: result.outputTokens ?? 0,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        cachedTokens: result.inputCachedTokens ?? 0,
                        reasoningTokens: 0  // Usage API does not return reasoning tokens separately
                    )
                    allEvents.append(event)
                }
            }

            pageToken = nextPage
            pagesRead += 1

            if !hasMore { break }
        } while pagesRead < Self.maxPages

        return allEvents
    }

    /// Returns a human-readable status string for the Settings UI.
    func testConnection() async -> String {
        guard let key = KeychainStore.get(account: KeychainAccount.openaiAdminKey),
              !key.isEmpty else {
            return "No Admin key configured"
        }

        let now = Date()
        let startTime = Int(now.addingTimeInterval(-86400).timeIntervalSince1970)
        let endTime = Int(now.timeIntervalSince1970)

        do {
            let (buckets, _, _) = try await fetchPage(
                key: key,
                startTime: startTime,
                endTime: endTime,
                pageToken: nil
            )
            let count = buckets.flatMap(\.results).count
            return "OK: \(count) records"
        } catch OpenAIUsageAPIError.httpError(let code, _) where code == 401 {
            return "Invalid Admin key (need sk-admin-... key, not sk-... user key)"
        } catch OpenAIUsageAPIError.httpError(let code, _) where code == 403 {
            return "Insufficient permissions"
        } catch OpenAIUsageAPIError.httpError(let code, let body) {
            return "HTTP \(code): \(body.prefix(120))"
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private helpers

    private func resolvedKey() throws -> String {
        guard let key = KeychainStore.get(account: KeychainAccount.openaiAdminKey),
              !key.isEmpty else {
            throw OpenAIUsageAPIError.missingKey
        }
        return key
    }

    private func fetchPage(
        key: String,
        startTime: Int,
        endTime: Int,
        pageToken: String?
    ) async throws -> (buckets: [Bucket], hasMore: Bool, nextPage: String?) {

        var components = URLComponents(string: Self.baseURL)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start_time", value: "\(startTime)"),
            URLQueryItem(name: "end_time", value: "\(endTime)"),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by[]", value: "model"),
            URLQueryItem(name: "limit", value: "180")
        ]
        if let token = pageToken {
            queryItems.append(URLQueryItem(name: "page", value: token))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw OpenAIUsageAPIError.parsingFailed("Could not construct request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Log only prefix — never the full key
        let keyPrefix = String(key.prefix(11)) + "..."
        _ = keyPrefix  // suppress unused warning; used for debugging only
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIUsageAPIError.httpError(0, error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIUsageAPIError.httpError(httpResponse.statusCode, body)
        }

        do {
            let parsed = try Self.decoder.decode(UsageResponse.self, from: data)
            return (parsed.data, parsed.hasMore, parsed.nextPage)
        } catch {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
            throw OpenAIUsageAPIError.parsingFailed("JSON decode failed: \(error.localizedDescription) — response: \(snippet)")
        }
    }
}
