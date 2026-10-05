import Foundation

// Thin reader for ~/.codex/auth.json
// Used by T6/T8 for optional API calls (account info, rate limits).
// All fields are optional — any missing/malformed value yields nil gracefully.

struct CodexAuthInfo {
    let accessToken: String?
    let accountId: String?
    let expiresAt: Date?
}

enum CodexAuth {
    // MARK: - Public

    static func read() -> CodexAuthInfo? {
        let authURL = codexHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> CodexAuthInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let tokens = obj["tokens"] as? [String: Any] ?? obj
        let accessToken = tokens["access_token"] as? String
        let accountId = tokens["account_id"] as? String
        let expiresAt = parseExpiresAt(tokens["expires_at"] ?? obj["expires_at"])

        // Return nil only if every field is nil (file existed but was empty/unexpected)
        if accessToken == nil, accountId == nil, expiresAt == nil { return nil }
        return CodexAuthInfo(accessToken: accessToken, accountId: accountId, expiresAt: expiresAt)
    }

    // MARK: - Helpers

    static func codexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    // expires_at may be an ISO-8601 string, a Unix timestamp (Double/Int), or absent
    private static func parseExpiresAt(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let str = value as? String {
            return iso8601Formatter.date(from: str) ?? iso8601FallbackFormatter.date(from: str)
        }
        if let ts = value as? Double { return Date(timeIntervalSince1970: ts) }
        if let ts = value as? Int    { return Date(timeIntervalSince1970: Double(ts)) }
        return nil
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
