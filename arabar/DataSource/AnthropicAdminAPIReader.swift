import Foundation

// MARK: - Error types

enum AnthropicAdminAPIError: Error {
    case missingKey
    case httpError(Int, String)
    case parsingFailed(String)
    case disabled
}

// MARK: - DTO types (private to this file)

private struct AdminUsageResponse: Decodable {
    let data: [UsageBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct UsageBucket: Decodable {
    let startingAt: Date
    let endingAt: Date
    let results: [UsageRow]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct UsageRow: Decodable {
    let uncachedInputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let outputTokens: Int
    let model: String
    let serviceTier: String?
    let workspaceId: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
        case serviceTier = "service_tier"
        case workspaceId = "workspace_id"
    }
}

// MARK: - AnthropicAdminAPIReader

final class AnthropicAdminAPIReader {

    private let session: URLSession

    // Shared ISO8601 decoder — tries fractional seconds first, then plain.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withMillis = ISO8601DateFormatter()
            withMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withMillis.date(from: str) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot parse date: \(str)"
            )
        }
        return d
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Returns last N days of API usage as a flat array of UsageEvent.
    /// Each Anthropic usage_report row gets mapped to one UsageEvent.
    /// Throws .missingKey if no Admin key in Keychain (= opt-out).
    func fetchEvents(lookbackDays: Int = 30) async throws -> [UsageEvent] {
        guard let key = KeychainStore.get(account: KeychainAccount.anthropicAdminKey), !key.isEmpty else {
            throw AnthropicAdminAPIError.missingKey
        }

        let now = Date()
        let startDate = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        var allEvents: [UsageEvent] = []
        var nextPage: String? = nil
        var keepFetching = true

        while keepFetching {
            let response = try await fetchPage(
                key: key,
                startingAt: startDate,
                endingAt: now,
                nextPage: nextPage
            )

            for bucket in response.data {
                for row in bucket.results {
                    let event = mapToUsageEvent(row: row, timestamp: bucket.startingAt)
                    allEvents.append(event)
                }
            }

            if response.hasMore, let page = response.nextPage, !page.isEmpty {
                nextPage = page
            } else {
                keepFetching = false
            }
        }

        return allEvents
    }

    /// Settings UI hook. Returns status string for display in preferences.
    func testConnection() async -> String {
        guard let key = KeychainStore.get(account: KeychainAccount.anthropicAdminKey), !key.isEmpty else {
            return "No Admin key configured"
        }

        let now = Date()
        let startDate = now.addingTimeInterval(-86_400) // last 24h

        do {
            let response = try await fetchPage(
                key: key,
                startingAt: startDate,
                endingAt: now,
                nextPage: nil
            )
            let rowCount = response.data.reduce(0) { $0 + $1.results.count }
            return "OK: \(rowCount) usage records"
        } catch AnthropicAdminAPIError.httpError(let code, _) where code == 401 || code == 403 {
            return "Invalid Admin key"
        } catch AnthropicAdminAPIError.httpError(let code, let body) {
            return "HTTP error \(code): \(body.prefix(80))"
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private helpers

    private func fetchPage(
        key: String,
        startingAt: Date,
        endingAt: Date,
        nextPage: String?
    ) async throws -> AdminUsageResponse {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "starting_at", value: Self.isoFormatter.string(from: startingAt)),
            URLQueryItem(name: "ending_at",   value: Self.isoFormatter.string(from: endingAt)),
            URLQueryItem(name: "group_by[]",  value: "workspace_id"),
            URLQueryItem(name: "group_by[]",  value: "model"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        if let page = nextPage {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AnthropicAdminAPIError.parsingFailed("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Never log full key — mask it
        print("[AnthropicAdminAPIReader] Using key \(key.prefix(8))...")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let (data, urlResponse) = try await session.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AnthropicAdminAPIError.parsingFailed("Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicAdminAPIError.httpError(httpResponse.statusCode, body)
        }

        do {
            return try Self.decoder.decode(AdminUsageResponse.self, from: data)
        } catch {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
            throw AnthropicAdminAPIError.parsingFailed("Decode failed: \(error) — response: \(snippet)")
        }
    }

    private func mapToUsageEvent(row: UsageRow, timestamp: Date) -> UsageEvent {
        UsageEvent(
            timestamp: timestamp,
            provider: .claude,
            model: row.model,
            sessionId: row.workspaceId ?? "default-workspace",
            messageId: nil,
            inputTokens: row.uncachedInputTokens,
            outputTokens: row.outputTokens,
            cacheReadTokens: row.cacheReadInputTokens,
            cacheCreationTokens: row.cacheCreationInputTokens,
            cachedTokens: 0,
            reasoningTokens: 0
        )
    }
}
