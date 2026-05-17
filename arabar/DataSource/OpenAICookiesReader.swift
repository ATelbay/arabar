import Foundation
import SQLite3
import os.log

private let openaiLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-openai")

// MARK: - Errors

enum OpenAICookiesError: Error, LocalizedError {
    case cookiesNotFound
    case browserUnsupported
    case decryptionFailed
    case accessDenied
    case httpError(Int)
    case parsingFailed(String)
    case disabled
    case appBoundEncryption
    case keychainAccessDenied
    case sessionExchangeFailed(httpCode: Int)

    var errorDescription: String? {
        switch self {
        case .sessionExchangeFailed(let code):
            return "ChatGPT session expired — log out and back in on chatgpt.com (HTTP \(code))"
        default:
            return nil
        }
    }
}

// MARK: - API response shapes

/// chatgpt.com/api/auth/session — NextAuth session endpoint.
/// Returns an accessToken (JWT) used to authorize /backend-api calls.
private struct SessionResponse: Decodable {
    struct User: Decodable {
        let id: String?
    }
    let user: User?
    let accessToken: String?
    let expires: String?
}

/// chatgpt.com/backend-api/wham/usage — schema reverse-engineered from CodexBar.
/// Returns authoritative rate-limit utilization (0..100) and reset times for both windows.
private struct WhamUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimitDetails: Decodable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct WindowSnapshot: Decodable {
        let usedPercent: Int
        let resetAt: Int             // Unix seconds
        let limitWindowSeconds: Int  // 18000 (5h) or 604800 (7d)

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}

// MARK: - OpenAICookiesReader

final class OpenAICookiesReader {

    // MARK: - Configuration

    private static let enabledKey = "cookies.enabled.openai"
    private static let sourceKey  = "cookies.source.openai"

    /// Session-token cookie name prefix used by NextAuth on chatgpt.com.
    private static let sessionCookiePrefix = "__Secure-next-auth.session-token"

    /// Primary usage endpoint — returns authoritative utilization for both 5h + 7d windows.
    private static let limitsURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // MARK: - State

    private let session: URLSession

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetches a UsageSnapshot from ChatGPT subscription usage endpoints.
    /// Throws `OpenAICookiesError.disabled` if the opt-in flag is not set.
    func fetchSnapshot() async throws -> UsageSnapshot {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            throw OpenAICookiesError.disabled
        }

        let source = BrowserSource(
            rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "safari"
        ) ?? .safari

        let cookieString = try extractCookieHeader(from: source)
        return try await fetchUsage(cookieHeader: cookieString)
    }

    /// Returns a human-readable connection status string (for Settings UI / T12).
    func testConnection() async -> String {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            return "Disabled (opt-in not set)"
        }
        do {
            let source = BrowserSource(
                rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "safari"
            ) ?? .safari
            let cookieStr = try extractCookieHeader(from: source)
            let masked = cookieStr.prefix(20).appending("…[masked]")
            debugLog(openaiLog, "Cookie header prefix: \(masked)")

            let snap = try await fetchUsage(cookieHeader: cookieStr)
            let pct = snap.sessionWindow.percentUsed.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
            return "Connected — session window \(pct) used"
        } catch OpenAICookiesError.cookiesNotFound {
            return "Error: no chatgpt.com cookies found. Are you logged in?"
        } catch OpenAICookiesError.keychainAccessDenied {
            return "Open Keychain Access.app, find 'Chrome Safe Storage', and add arabar to its Access Control list."
        } catch OpenAICookiesError.decryptionFailed {
            return "Error: Cookie decryption failed"
        } catch OpenAICookiesError.appBoundEncryption {
            return "Chrome App-Bound Encryption (v20) cookies not supported — try Safari or Chrome v126-"
        } catch OpenAICookiesError.accessDenied {
            return "Error: Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access"
        } catch OpenAICookiesError.httpError(let code) {
            return "Error: HTTP \(code) from ChatGPT API"
        } catch OpenAICookiesError.sessionExchangeFailed(let code) {
            return "ChatGPT session expired — log out and back in on chatgpt.com (HTTP \(code))"
        } catch OpenAICookiesError.parsingFailed(let detail) {
            return "Error: response parse failed — \(detail)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Cookie extraction

    private func mapSafariError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as SafariCookiesError {
            switch e.category {
            case .fileNotFound:           throw OpenAICookiesError.cookiesNotFound
            case .accessDenied:           throw OpenAICookiesError.accessDenied
            case .invalidFormat(let msg): throw OpenAICookiesError.parsingFailed(msg)
            }
        }
    }

    private func extractCookieHeader(from source: BrowserSource) throws -> String {
        switch source {
        case .chrome:
            return try chromeLikeCookieHeaderFromProfiles(
                profilePaths: chromeProfileCookiesPaths(),
                keychainService: "Chrome Safe Storage",
                keychainAccount: "Chrome"
            )
        case .brave:
            return try chromeLikeCookieHeaderFromProfiles(
                profilePaths: braveProfileCookiesPaths(),
                keychainService: "Brave Safe Storage",
                keychainAccount: "Brave"
            )
        case .edge:
            return try chromeLikeCookieHeaderFromProfiles(
                profilePaths: edgeProfileCookiesPaths(),
                keychainService: "Microsoft Edge Safe Storage",
                keychainAccount: "Microsoft Edge"
            )
        case .safari:
            let cookies = try mapSafariError {
                try SafariBinaryCookies.readCookies(matching: ["chatgpt.com"])
            }
            // Collect all session-token cookies (bare + chunks)
            let tokenCookies = cookies.filter { $0.name.hasPrefix(Self.sessionCookiePrefix) }
            guard !tokenCookies.isEmpty else { throw OpenAICookiesError.cookiesNotFound }
            return assembleNextAuthCookieHeader(pairs: tokenCookies.map { ($0.name, $0.value) })
        }
    }

    // MARK: - Profile path enumeration

    private func chromeProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Google/Chrome")
    }

    private func braveProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser")
    }

    private func edgeProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Microsoft Edge")
    }

    // MARK: - Chrome cookie extraction (multi-profile)

    /// Tries each profile DB in order; returns on first profile that yields chatgpt cookies.
    private func chromeLikeCookieHeaderFromProfiles(
        profilePaths: [String],
        keychainService: String,
        keychainAccount: String
    ) throws -> String {
        guard !profilePaths.isEmpty else { throw OpenAICookiesError.cookiesNotFound }

        let aesKeys = try chromeAESKeys(account: keychainAccount, service: keychainService)
        var lastError: Error = OpenAICookiesError.cookiesNotFound

        for dbPath in profilePaths {
            do {
                let header = try chromeCookieHeaderFromDB(path: dbPath, aesKeys: aesKeys)
                return header
            } catch OpenAICookiesError.cookiesNotFound {
                lastError = OpenAICookiesError.cookiesNotFound
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private func chromeCookieHeaderFromDB(path: String, aesKeys: [Data]) throws -> String {
        let tmp: URL
        do {
            // Always copy — Chrome may lock the file
            tmp = try {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("arabar_\(UUID().uuidString).db")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                return url
            }()
        } catch {
            throw OpenAICookiesError.cookiesNotFound
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw OpenAICookiesError.cookiesNotFound
        }
        defer { sqlite3_close(db) }
        let dbVersion = ChromiumCookieDB.readCookieDBVersion(db: db!)
        let hasHashPrefix = dbVersion >= 24
        debugLog(openaiLog, "DB meta version=\(dbVersion), hasHashPrefix=\(hasHashPrefix ? "YES" : "NO")")
        return try extractChromeCookies(db: db!, aesKeys: aesKeys, hasHashPrefix: hasHashPrefix)
    }

    private func extractChromeCookies(db: OpaquePointer, aesKeys: [Data], hasHashPrefix: Bool) throws -> String {
        // Match exact prefix; ORDER BY name gives .0, .1, … in order
        let sql = "SELECT name, value, encrypted_value FROM cookies WHERE host_key LIKE ?1 AND name LIKE ?2 ORDER BY name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenAICookiesError.parsingFailed("SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "%chatgpt.com%", -1, transient)
        let namePattern = Self.sessionCookiePrefix + "%"
        sqlite3_bind_text(stmt, 2, namePattern, -1, transient)

        let keylens = aesKeys.map { $0.count }.map(String.init).joined(separator: ",")
        debugLog(openaiLog, "keychain candidates: \(aesKeys.count), keylens=[\(keylens)]")
        var pairs: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)

            var value: String?

            if let valPtr = sqlite3_column_text(stmt, 1), sqlite3_column_bytes(stmt, 1) > 0 {
                let v = String(cString: valPtr)
                if !v.isEmpty { value = v }
            }

            if value == nil || value!.isEmpty {
                let blobLen = Int(sqlite3_column_bytes(stmt, 2))
                if blobLen > 0, let blobPtr = sqlite3_column_blob(stmt, 2) {
                    let encData = Data(bytes: blobPtr, count: blobLen)
                    let pfx3 = String(data: encData.prefix(3), encoding: .utf8) ?? "??"
                    debugLog(openaiLog, "cookie \(name): \(blobLen) bytes, prefix=\(pfx3)")
                    if encData.count >= 3, pfx3 == "v20" {
                        throw OpenAICookiesError.appBoundEncryption
                    }
                    for (idx, key) in aesKeys.enumerated() {
                        do {
                            let plaintext = try ChromiumCookieDB.decryptChromeCookieBlob(encData, key: key, hasHashPrefix: hasHashPrefix)
                            let valid = plaintext.count > 20
                            debugLog(openaiLog, "key #\(idx) → decrypt OK, len=\(plaintext.count), valid=\(valid ? "YES" : "NO")")
                            if valid { value = plaintext; break }
                        } catch {
                            debugLog(openaiLog, "key #\(idx) → decrypt FAILED: \(error)")
                        }
                    }
                    if value == nil {
                        debugLog(openaiLog, "cookie \(name): no key produced valid plaintext, skipping row")
                        continue
                    }
                }
            }

            if let v = value, !v.isEmpty {
                pairs.append((name, v))
            }
        }

        guard !pairs.isEmpty else { throw OpenAICookiesError.cookiesNotFound }
        return assembleNextAuthCookieHeader(pairs: pairs)
    }

    // MARK: - NextAuth cookie assembly

    /// Builds the Cookie header for NextAuth split tokens.
    /// If the bare token exists, prefer it; otherwise sort chunks by numeric suffix and send as-split.
    /// The browser sends split cookies as separate name=value pairs; NextAuth reassembles server-side.
    private func assembleNextAuthCookieHeader(pairs: [(String, String)]) -> String {
        // Separate bare token from numbered chunks
        let bare = pairs.first(where: { $0.0 == Self.sessionCookiePrefix })
        let chunks = pairs
            .filter { $0.0 != Self.sessionCookiePrefix && $0.0.hasPrefix(Self.sessionCookiePrefix + ".") }
            .sorted { a, b in
                let na = Int(a.0.dropFirst(Self.sessionCookiePrefix.count + 1)) ?? 0
                let nb = Int(b.0.dropFirst(Self.sessionCookiePrefix.count + 1)) ?? 0
                return na < nb
            }

        if let bare = bare {
            // Single-chunk case — also include any other non-session cookies if needed
            return "\(bare.0)=\(bare.1)"
        }

        // Split-chunk case: send as the browser would (each chunk as its own name=value pair)
        return chunks.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    // MARK: - Chrome AES key

    /// Reads all Chrome Safe Storage entries from the system keychain and derives one AES-128-CBC
    /// key per non-empty password via ChromiumKeychain. Returns an array so callers can try each in turn.
    private func chromeAESKeys(account: String, service: String) throws -> [Data] {
        let passwordCandidates = ChromiumKeychain.readAllCandidateKeys(service: service, account: account)
        guard !passwordCandidates.isEmpty else {
            throw OpenAICookiesError.keychainAccessDenied
        }
        let keys = passwordCandidates.compactMap { ChromiumKeychain.deriveAESKey(from: $0) }
        guard !keys.isEmpty else { throw OpenAICookiesError.decryptionFailed }
        return keys
    }

    // MARK: - HTTP requests

    /// Step 1: Exchange cookies for a NextAuth Bearer token.
    /// Returns `(accessToken, accountId?)`. Throws `.sessionExchangeFailed` on any failure.
    private func fetchAccessToken(cookieHeader: String) async throws -> (accessToken: String, accountId: String?) {
        let sessionURL = URL(string: "https://chatgpt.com/api/auth/session")!
        var req = URLRequest(url: sessionURL)
        req.timeoutInterval = 8
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICookiesError.parsingFailed("non-HTTP response from session endpoint")
        }
        debugLog(openaiLog, "auth/session HTTP \(http.statusCode), body=\(data.count) bytes")

        guard http.statusCode == 200 else {
            debugLog(openaiLog, .error, "auth/session failed with HTTP \(http.statusCode)")
            throw OpenAICookiesError.sessionExchangeFailed(httpCode: http.statusCode)
        }

        let sessionResp: SessionResponse
        do {
            sessionResp = try JSONDecoder().decode(SessionResponse.self, from: data)
        } catch {
            let fragment = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            debugLog(openaiLog, .error, "auth/session parse FAILED: \(error.localizedDescription), body=\(fragment)")
            throw OpenAICookiesError.parsingFailed("session response: \(error.localizedDescription)")
        }

        guard let token = sessionResp.accessToken, !token.isEmpty else {
            debugLog(openaiLog, .error, "auth/session: accessToken field missing or empty")
            throw OpenAICookiesError.sessionExchangeFailed(httpCode: 200)
        }

        let accountId = sessionResp.user?.id
        debugLog(openaiLog, "auth/session: token length=\(token.count), accountId present=\(accountId != nil ? "YES" : "NO")")
        return (token, accountId)
    }

    private func fetchUsage(cookieHeader: String) async throws -> UsageSnapshot {
        // Step 1: Exchange cookies for a Bearer token via NextAuth session endpoint.
        let (accessToken, accountId) = try await fetchAccessToken(cookieHeader: cookieHeader)

        // Step 2: Fetch wham/usage with Bearer auth — do NOT send Cookie header here.
        var req = URLRequest(url: Self.limitsURL)
        req.timeoutInterval = 8
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let aid = accountId {
            req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICookiesError.parsingFailed("non-HTTP response")
        }
        debugLog(openaiLog, "wham/usage HTTP \(http.statusCode), body=\(data.count) bytes")

        if http.statusCode == 401 || http.statusCode == 403 {
            return emptySnapshot()
        }
        guard http.statusCode == 200 else {
            throw OpenAICookiesError.httpError(http.statusCode)
        }

        do {
            let usage = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
            debugLog(openaiLog, "wham parsed: plan=\(usage.planType ?? "?"), primary=\(usage.rateLimit?.primaryWindow.map { "\($0.usedPercent)%" } ?? "nil"), secondary=\(usage.rateLimit?.secondaryWindow.map { "\($0.usedPercent)%" } ?? "nil")")
            return buildSnapshot(from: usage)
        } catch {
            let fragment = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            debugLog(openaiLog, "wham parse FAILED: \(error.localizedDescription), body=\(fragment)")
            throw OpenAICookiesError.parsingFailed(error.localizedDescription)
        }
    }

    // MARK: - Snapshot construction

    private func buildSnapshot(from usage: WhamUsageResponse) -> UsageSnapshot {
        let primary = window(from: usage.rateLimit?.primaryWindow, fallbackHours: 5)
        let secondary = window(from: usage.rateLimit?.secondaryWindow, fallbackHours: 168)
        return UsageSnapshot(
            provider: .codex,
            generatedAt: Date(),
            sessionWindow: primary,
            weeklyWindow: secondary,
            totalEventsInPeriod: 0
        )
    }

    private func window(from snap: WhamUsageResponse.WindowSnapshot?, fallbackHours: Int) -> WindowSnapshot {
        guard let s = snap else {
            return WindowSnapshot(durationHours: fallbackHours, tokensUsed: 0, costUSD: 0, percentUsed: nil, resetAt: nil, percentSource: .unknown)
        }
        let hours = s.limitWindowSeconds > 0 ? s.limitWindowSeconds / 3600 : fallbackHours
        // wham/usage reports used_percent as an integer with a floor of 1 — any nonzero
        // activity (including the rolling 7d window catching old sessions) shows as 1%,
        // which makes idle users see "99% left". Subtract 1 so the floor reads as 100%.
        let adjustedUsedPercent = max(0, s.usedPercent - 1)
        return WindowSnapshot(
            durationHours: hours,
            tokensUsed: 0,
            costUSD: 0,
            percentUsed: Double(adjustedUsedPercent) / 100.0,
            resetAt: Date(timeIntervalSince1970: TimeInterval(s.resetAt)),
            percentSource: .authoritative
        )
    }

    private func emptySnapshot() -> UsageSnapshot {
        let win = WindowSnapshot(durationHours: 5, tokensUsed: 0, costUSD: 0, percentUsed: nil, resetAt: nil, percentSource: .unknown)
        return UsageSnapshot(
            provider: .codex,
            generatedAt: Date(),
            sessionWindow: win,
            weeklyWindow: win,
            totalEventsInPeriod: 0
        )
    }
}
