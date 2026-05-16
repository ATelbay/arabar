import Foundation

enum StatusPagePoller {

    // MARK: - Private types

    private struct Response: Decodable {
        let page: Page
        let status: Status

        struct Page: Decodable {
            let url: String?
        }

        struct Status: Decodable {
            let indicator: String
            let description: String?
        }
    }

    // MARK: - URL mapping

    private static func statusURL(for provider: Provider) -> URL {
        switch provider {
        case .claude:
            return URL(string: "https://status.anthropic.com/api/v2/status.json")!
        case .codex:
            return URL(string: "https://status.openai.com/api/v2/status.json")!
        }
    }

    // MARK: - Indicator → StatusLevel

    private static func level(from indicator: String) -> StatusLevel {
        switch indicator {
        case "none":     return .operational
        case "minor":    return .degraded
        case "major":    return .partialOutage
        case "critical": return .majorOutage
        default:         return .unknown
        }
    }

    // MARK: - Public API

    static func fetch(provider: Provider) async -> StatusInfo {
        let now = Date()
        let url = statusURL(for: provider)

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(Response.self, from: data)

            let pageURL = response.page.url.flatMap { URL(string: $0) }
            let statusLevel = level(from: response.status.indicator)

            return StatusInfo(
                provider: provider,
                level: statusLevel,
                summary: response.status.description,
                incidentURL: pageURL,
                fetchedAt: now
            )
        } catch {
            // On any network or decode error, return unknown status
            return StatusInfo(
                provider: provider,
                level: .unknown,
                summary: nil,
                incidentURL: nil,
                fetchedAt: now
            )
        }
    }
}
