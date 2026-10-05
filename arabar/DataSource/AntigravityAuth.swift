import Foundation

/// Read-only access to the Antigravity CLI (`agy`) Google sign-in.
///
/// agy saves its OAuth token with zalando/go-keyring, which on macOS writes a generic
/// password (service "gemini", account "antigravity") through `/usr/bin/security`. Reading
/// it back through the same tool therefore needs no extra Keychain approval. Google does not
/// rotate refresh tokens, so refreshing the access token in memory never signs agy out;
/// arabar never writes the item back.
struct AntigravityCredentials: Equatable {
    let accessToken: String?
    let refreshToken: String?
    let expiry: Date?
    /// Present only if agy stored the client alongside the token.
    let client: GeminiOAuthClient?

    func validAccessToken(now: Date = Date()) -> String? {
        guard let accessToken, !accessToken.isEmpty, let expiry,
              expiry.timeIntervalSince(now) > 60 else { return nil }
        return accessToken
    }
}

enum AntigravityAuth {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    static let quotaBaseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:"

    // MARK: - Keychain

    /// True when agy has a saved sign-in. Reads attributes only (no secret).
    static func hasSavedLogin() -> Bool {
        runSecurity(["find-generic-password", "-s", keychainService, "-a", keychainAccount]) != nil
    }

    static func readCredentials() -> AntigravityCredentials? {
        guard let raw = runSecurity(["find-generic-password", "-w", "-s", keychainService, "-a", keychainAccount]) else {
            return nil
        }
        return decode(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Accepts go-keyring's encodings (`go-keyring-base64:` / `go-keyring-encoded:` hex) and
    /// the common token JSON spellings (Go oauth2.Token and Node-style fields).
    static func decode(_ raw: String) -> AntigravityCredentials? {
        var payload = raw
        if payload.hasPrefix("go-keyring-base64:") {
            guard let data = Data(base64Encoded: String(payload.dropFirst("go-keyring-base64:".count))),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            payload = text
        } else if payload.hasPrefix("go-keyring-encoded:") {
            let hex = Array(payload.dropFirst("go-keyring-encoded:".count))
            guard hex.count.isMultiple(of: 2) else { return nil }
            var bytes: [UInt8] = []
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
                bytes.append(byte)
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
            payload = text
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return nil
        }
        // Some wrappers nest the oauth2 token one level down.
        let token = (object["token"] as? [String: Any]) ?? (object["tokens"] as? [String: Any]) ?? object
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = token[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let expiry: Date? = {
            for key in ["expiry", "expires_at", "expiresAt", "expiry_date", "expiryDate"] {
                let value = token[key] ?? object[key]
                if let text = value as? String, let date = parseDate(text) { return date }
                if let number = value as? NSNumber, number.doubleValue > 0 {
                    let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
                    return Date(timeIntervalSince1970: seconds)
                }
            }
            return nil
        }()
        let access = string("access_token", "accessToken")
        let refresh = string("refresh_token", "refreshToken")
        guard access != nil || refresh != nil else { return nil }
        let client = string("client_id", "clientId").flatMap { id in
            string("client_secret", "clientSecret").map { GeminiOAuthClient(id: id, secret: $0) }
        }
        return AntigravityCredentials(accessToken: access, refreshToken: refresh, expiry: expiry, client: client)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Go marshals time.Time with nanoseconds, which ISO8601DateFormatter rejects.
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            return formatter.date(from: String(text[..<dot]) + String(text[zone...]))
        }
        return nil
    }

    // MARK: - Project

    static func projectId(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let url = home.appendingPathComponent(".gemini/antigravity-cli/cache/default_project_id.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - OAuth client

    static func binaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + path.split(separator: ":").map(String.init)
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("agy").resolvingSymlinksInPath()
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Candidate installed-app OAuth clients found in the agy executable. Client IDs and
    /// secrets are not stored next to each other, so every combination is returned and the
    /// token endpoint decides which pair is agy's.
    static func oauthClients(in binary: URL?) -> [GeminiOAuthClient] {
        guard let binary, let data = try? Data(contentsOf: binary, options: .mappedIfSafe) else { return [] }
        let ids = matches(in: data, anchor: Data(".apps.googleusercontent.com".utf8), anchorIsSuffix: true)
        let secrets = matches(in: data, anchor: Data("GOCSPX-".utf8), anchorIsSuffix: false)
        return ids.flatMap { id in secrets.map { GeminiOAuthClient(id: id, secret: $0) } }
    }

    private static func matches(in data: Data, anchor: Data, anchorIsSuffix: Bool) -> [String] {
        func isTokenByte(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
        var found: [String] = []
        var searchStart = data.startIndex
        while let range = data.range(of: anchor, in: searchStart..<data.endIndex) {
            searchStart = range.upperBound
            var start = range.lowerBound
            var end = range.upperBound
            if anchorIsSuffix {
                while start > data.startIndex, isTokenByte(data[data.index(before: start)]) {
                    start = data.index(before: start)
                }
            } else {
                while end < data.endIndex, isTokenByte(data[end]) { end = data.index(after: end) }
            }
            guard let text = String(data: data[start..<end], encoding: .ascii) else { continue }
            let valid = anchorIsSuffix
                ? text.range(of: #"^[0-9]{6,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
                : text.count >= 30 && text.count <= 40
            if valid, !found.contains(text) { found.append(text) }
        }
        return found
    }
}
