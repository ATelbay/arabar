import Foundation

/// Read-only view of the Kimi Code CLI login (`~/.kimi-code`).
///
/// Kimi rotates refresh tokens and the CLI persists each rotation under a lock, so arabar
/// must never refresh on the CLI's behalf — doing so would sign the CLI out. We only reuse
/// the access token while it is still valid (the CLI keeps it fresh while it is in use;
/// it lives ~15 minutes) and otherwise fall back to a saved API key.
struct KimiCodeCLIAuth: Equatable {
    static let mainlandBaseURL = "https://api.kimi.com/coding/v1"
    static let globalBaseURL = "https://api.kimi.ai/coding/v1"

    /// Coding API base URL the CLI talks to, e.g. `https://api.kimi.ai/coding/v1`.
    let baseURL: String
    let accessToken: String?
    let expiresAt: Date?

    var host: String { URL(string: baseURL)?.host ?? baseURL }

    func validToken(now: Date = Date()) -> String? {
        guard let accessToken, !accessToken.isEmpty, let expiresAt,
              expiresAt.timeIntervalSince(now) > 30 else { return nil }
        return accessToken
    }

    /// nil when Kimi Code CLI has never been set up on this Mac.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> KimiCodeCLIAuth? {
        let root = home.appendingPathComponent(".kimi-code", isDirectory: true)
        let config = (try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8))
            .map(parseTOMLSections) ?? [:]
        let provider = config[#"providers."managed:kimi-code""#] ?? [:]
        let oauth = config[#"providers."managed:kimi-code".oauth"#] ?? [:]
        let region = (try? String(contentsOf: root.appendingPathComponent("region"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let credentialsDir = root.appendingPathComponent("credentials", isDirectory: true)
        // The oauth `key` names the credential file; never let it escape the directory.
        let name = (oauth["key"].map { ($0 as NSString).lastPathComponent }).flatMap { $0.isEmpty || $0.hasPrefix(".") ? nil : $0 }
            ?? "kimi-code"
        let credentials = (try? Data(contentsOf: credentialsDir.appendingPathComponent("\(name).json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        guard !config.isEmpty || credentials != nil else { return nil }

        let baseURL = provider["base_url"].flatMap { $0.hasPrefix("https://") ? $0 : nil }
            ?? (region == "global" ? globalBaseURL : mainlandBaseURL)
        let expiresAt = (credentials?["expires_at"] as? NSNumber)
            .flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil }
        return KimiCodeCLIAuth(
            baseURL: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL,
            accessToken: credentials?["access_token"] as? String,
            expiresAt: expiresAt
        )
    }

    /// Minimal TOML reader: `[section]` headers and `key = "string"` pairs, which is all
    /// arabar needs from the CLI config.
    static func parseTOMLSections(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""),
                  let closing = value.dropFirst().firstIndex(of: "\"") else { continue }
            sections[current, default: [:]][key] = String(value[value.index(after: value.startIndex)..<closing])
        }
        return sections
    }
}
