import Foundation
import SQLite3
import os.log

private let claudeLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-claude")

// MARK: - Public Types

enum BrowserSource: String, Codable, CaseIterable {
    case safari, chrome, brave, edge
}

enum ClaudeCookiesError: Error, LocalizedError {
    case cookiesNotFound
    case browserUnsupported
    case decryptionFailed
    case accessDenied
    case httpError(Int)
    /// Rejected by the edge (Cloudflare challenge / bot protection), not by the session.
    /// Re-logging in does not help, so this must not be reported as an expired session.
    case blockedByEdge(Int)
    case parsingFailed(String)
    case disabled
    case appBoundEncryption
    case keychainAccessDenied

    var errorDescription: String? {
        switch self {
        case .cookiesNotFound: return "No claude.ai session cookie found in the selected browser"
        case .browserUnsupported: return "Selected browser is not supported"
        case .decryptionFailed: return "Could not decrypt the browser cookie"
        case .accessDenied: return "Full Disk Access is required to read browser cookies"
        case .httpError(let code): return "claude.ai returned HTTP \(code)"
        case .blockedByEdge(let code): return "claude.ai blocked the request (HTTP \(code), bot protection) — try again later"
        case .parsingFailed(let detail): return "Unexpected claude.ai response: \(detail)"
        case .disabled: return "Browser cookies are disabled"
        case .appBoundEncryption: return "Chrome App-Bound Encryption cookies are not supported"
        case .keychainAccessDenied: return "Keychain access to the browser's Safe Storage key was denied"
        }
    }

    /// 403 from claude.ai means either a dead session (JSON permission error) or an edge
    /// challenge (HTML page, `cf-mitigated` header). Only the former needs a re-login.
    static func forHTTPFailure(_ response: HTTPURLResponse) -> ClaudeCookiesError {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isEdgeChallenge = response.value(forHTTPHeaderField: "cf-mitigated") != nil
            || contentType.contains("text/html")
        if response.statusCode == 403, isEdgeChallenge {
            return .blockedByEdge(response.statusCode)
        }
        return .httpError(response.statusCode)
    }
}

// MARK: - ClaudeCookiesReader

final class ClaudeCookiesReader {

    // MARK: - Constants

    private static let claudeDomain = "claude.ai"
    private static let sessionCookieName = "sessionKey"
    private static let lastActiveOrgCookieName = "lastActiveOrg"
    private static let baseURL = "https://claude.ai/api"
    private static let userDefaultsEnabledKey = "cookies.enabled.claude"
    private static let userDefaultsSourceKey = "cookies.source.claude"

    // MARK: - Properties

    private let session: URLSession

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetches UsageSnapshot from claude.ai using browser session cookies.
    /// Throws `.disabled` if opt-in is off.
    func fetchSnapshot() async throws -> UsageSnapshot {
        guard UserDefaults.standard.bool(forKey: Self.userDefaultsEnabledKey) else {
            throw ClaudeCookiesError.disabled
        }
        let source = BrowserSource(
            rawValue: UserDefaults.standard.string(forKey: Self.userDefaultsSourceKey) ?? ""
        ) ?? .safari

        let browserSession = try extractSession(from: source)
        let sessionKey = browserSession.sessionKey
        let orgId = try await fetchOrgId(sessionKey: sessionKey, preferredOrgId: browserSession.lastActiveOrgId)
        let snapshot = try await fetchUsage(orgId: orgId, sessionKey: sessionKey)
        return snapshot
    }

    /// Returns a human-readable status string for Settings UI.
    func testConnection() async -> String {
        guard UserDefaults.standard.bool(forKey: Self.userDefaultsEnabledKey) else {
            return "Disabled (opt-in required)"
        }
        let source = BrowserSource(
            rawValue: UserDefaults.standard.string(forKey: Self.userDefaultsSourceKey) ?? ""
        ) ?? .safari

        do {
            let browserSession = try extractSession(from: source)
            let sessionKey = browserSession.sessionKey
            let orgId = try await fetchOrgId(sessionKey: sessionKey, preferredOrgId: browserSession.lastActiveOrgId)
            if let email = await fetchAccountEmail(orgId: orgId, sessionKey: sessionKey) {
                return "Logged in as \(email)"
            }
            return "Connected (org: \(orgId.prefix(8))…)"
        } catch ClaudeCookiesError.cookiesNotFound {
            return "No cookies — log in to claude.ai in \(source.rawValue.capitalized)"
        } catch ClaudeCookiesError.browserUnsupported {
            return "Browser \(source.rawValue) not supported"
        } catch ClaudeCookiesError.keychainAccessDenied {
            return "Open Keychain Access.app, find '\(Self.safeStorageServiceName(for: source))', and add arabar to its Access Control list."
        } catch ClaudeCookiesError.decryptionFailed {
            return "Error: Cookie decryption failed"
        } catch ClaudeCookiesError.appBoundEncryption {
            return "Chrome App-Bound Encryption (v20) cookies not supported — try Safari or Chrome v126-"
        } catch ClaudeCookiesError.accessDenied {
            return "Error: Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access"
        } catch ClaudeCookiesError.blockedByEdge(let code) {
            return "Error: HTTP \(code) — claude.ai bot protection blocked the request; try again later"
        } catch ClaudeCookiesError.httpError(let code) {
            return "Error: HTTP \(code) — session may have expired"
        } catch ClaudeCookiesError.parsingFailed(let msg) {
            return "Error: \(msg)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Cookie Extraction

    private func mapSafariError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as SafariCookiesError {
            switch e.category {
            case .fileNotFound:           throw ClaudeCookiesError.cookiesNotFound
            case .accessDenied:           throw ClaudeCookiesError.accessDenied
            case .invalidFormat(let msg): throw ClaudeCookiesError.parsingFailed(msg)
            }
        }
    }

    private static func safeStorageServiceName(for source: BrowserSource) -> String {
        switch source {
        case .safari: return "Safari cookies"
        case .chrome: return "Chrome Safe Storage"
        case .brave: return "Brave Safe Storage"
        case .edge: return "Microsoft Edge Safe Storage"
        }
    }

    /// Session cookie plus the org the user last had open in the browser (`lastActiveOrg`),
    /// so multi-org accounts report the same organization's limits as claude.ai does.
    private struct BrowserSession {
        let sessionKey: String
        let lastActiveOrgId: String?
    }

    private func extractSession(from source: BrowserSource) throws -> BrowserSession {
        switch source {
        case .safari:
            let cookies = try mapSafariError {
                try SafariBinaryCookies.readCookies(matching: ["claude.ai"])
            }
            let now = Date()
            let live = cookies.filter { !$0.value.isEmpty && ($0.expiry == nil || $0.expiry! > now) }
            guard let sessionCookie = live.first(where: { $0.name == Self.sessionCookieName }) else {
                throw ClaudeCookiesError.cookiesNotFound
            }
            let org = live.first(where: { $0.name == Self.lastActiveOrgCookieName })?.value
            return BrowserSession(sessionKey: sessionCookie.value, lastActiveOrgId: org)
        case .chrome:
            return try extractFromProfiles(
                paths: chromeCookiesPaths(),
                safeStorageService: "Chrome Safe Storage",
                safeStorageAccount: "Chrome"
            )
        case .brave:
            return try extractFromProfiles(
                paths: braveCookiesPaths(),
                safeStorageService: "Brave Safe Storage",
                safeStorageAccount: "Brave"
            )
        case .edge:
            return try extractFromProfiles(
                paths: edgeCookiesPaths(),
                safeStorageService: "Microsoft Edge Safe Storage",
                safeStorageAccount: "Microsoft Edge"
            )
        }
    }

    // MARK: - Cookie DB Paths (multi-profile)

    private func chromeCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Google/Chrome")
    }

    private func braveCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser")
    }

    private func edgeCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ChromiumCookieDB.profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Microsoft Edge")
    }

    // MARK: - Multi-profile extraction

    /// Tries each profile DB in order; returns the first that contains the cookie.
    private func extractFromProfiles(
        paths: [String],
        safeStorageService: String,
        safeStorageAccount: String
    ) throws -> BrowserSession {
        guard !paths.isEmpty else { throw ClaudeCookiesError.cookiesNotFound }
        var lastError: Error = ClaudeCookiesError.cookiesNotFound
        for path in paths {
            do {
                let value = try extractChromeSessionKey(
                    dbPath: path,
                    safeStorageService: safeStorageService,
                    safeStorageAccount: safeStorageAccount
                )
                return value
            } catch {
                // A broken or stale profile must not hide a usable session in another profile.
                if case ClaudeCookiesError.cookiesNotFound = error { continue }
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Chrome / Chromium Cookie Decryption

    /// Reads the Chromium-family SQLite cookies DB and returns the `sessionKey` value for claude.ai,
    /// plus `lastActiveOrg` when it can be read (best-effort, never fails the session read).
    private func extractChromeSessionKey(
        dbPath: String,
        safeStorageService: String,
        safeStorageAccount: String
    ) throws -> BrowserSession {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ClaudeCookiesError.cookiesNotFound
        }

        let tmpURL: URL
        do {
            tmpURL = try ChromiumCookieDB.snapshotToTemp(dbPath)
        } catch {
            throw ClaudeCookiesError.cookiesNotFound
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ClaudeCookiesError.cookiesNotFound
        }
        defer { sqlite3_close(db) }

        let dbVersion = ChromiumCookieDB.readCookieDBVersion(db: db!)
        let hasHashPrefix = dbVersion >= 24
        debugLog(claudeLog, "DB meta version=\(dbVersion), hasHashPrefix=\(hasHashPrefix ? "YES" : "NO")")

        let (plainValue, encryptedData) = try readCookieRow(db: db!, name: Self.sessionCookieName)

        // Row not found at all → not found
        if plainValue == nil && encryptedData == nil {
            throw ClaudeCookiesError.cookiesNotFound
        }

        // Keys are derived lazily and at most once per DB, shared by both cookies.
        var derivedKeys: [Data]?
        func aesKeysOrThrow() throws -> [Data] {
            if let derivedKeys { return derivedKeys }
            let passwordCandidates = ChromiumKeychain.readAllCandidateKeys(service: safeStorageService, account: safeStorageAccount)
            guard !passwordCandidates.isEmpty else { throw ClaudeCookiesError.keychainAccessDenied }
            let keys = passwordCandidates.compactMap { ChromiumKeychain.deriveAESKey(from: $0) }
            debugLog(claudeLog, "keychain candidates: \(keys.count)")
            guard !keys.isEmpty else { throw ClaudeCookiesError.decryptionFailed }
            derivedKeys = keys
            return keys
        }

        func lastActiveOrg() -> String? {
            guard let (plain, encrypted) = try? readCookieRow(db: db!, name: Self.lastActiveOrgCookieName) else { return nil }
            if let plain, !plain.isEmpty { return plain }
            guard let encrypted, !encrypted.isEmpty, let keys = try? aesKeysOrThrow() else { return nil }
            return keys.lazy.compactMap {
                try? ChromiumCookieDB.decryptChromeCookieBlob(encrypted, key: $0, hasHashPrefix: hasHashPrefix)
            }.first { UUID(uuidString: $0) != nil }
        }

        if let plain = plainValue, !plain.isEmpty {
            return BrowserSession(sessionKey: plain, lastActiveOrgId: lastActiveOrg())
        }

        guard let encrypted = encryptedData, !encrypted.isEmpty else {
            throw ClaudeCookiesError.cookiesNotFound
        }

        // Detect App-Bound Encryption (v20+) — cannot decrypt
        if encrypted.count >= 3,
           let prefix = String(data: encrypted.prefix(3), encoding: .utf8),
           prefix == "v20" {
            throw ClaudeCookiesError.appBoundEncryption
        }

        let prefix3 = String(data: encrypted.prefix(3), encoding: .utf8) ?? "??"
        debugLog(claudeLog, "cookie blob: \(encrypted.count) bytes, prefix=\(prefix3), profile=\(dbPath)")

        let aesKeys = try aesKeysOrThrow()
        for (idx, key) in aesKeys.enumerated() {
            do {
                let decrypted = try ChromiumCookieDB.decryptChromeCookieBlob(encrypted, key: key, hasHashPrefix: hasHashPrefix)
                let valid = decrypted.hasPrefix("sk-ant-")
                debugLog(claudeLog, "key #\(idx) → decrypt OK, len=\(decrypted.count), valid=\(valid ? "YES" : "NO")")
                if valid { return BrowserSession(sessionKey: decrypted, lastActiveOrgId: lastActiveOrg()) }
            } catch {
                debugLog(claudeLog, "key #\(idx) → decrypt FAILED: \(error)")
            }
        }
        throw ClaudeCookiesError.decryptionFailed
    }

    /// Newest non-expired claude.ai cookie row with the given name: (plaintext value, encrypted blob).
    private func readCookieRow(db: OpaquePointer, name: String) throws -> (String?, Data?) {
        let sql = "SELECT name, value, encrypted_value FROM cookies WHERE host_key IN (?1, ?2) AND name = ?3 AND (expires_utc = 0 OR expires_utc > ?4) ORDER BY expires_utc DESC LIMIT 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClaudeCookiesError.parsingFailed("SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, Self.claudeDomain, -1, transient)
        sqlite3_bind_text(stmt, 2, "." + Self.claudeDomain, -1, transient)
        sqlite3_bind_text(stmt, 3, name, -1, transient)
        sqlite3_bind_int64(stmt, 4, Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000))

        var plainValue: String?
        var encryptedData: Data?
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1) {
                let val = String(cString: raw)
                if !val.isEmpty { plainValue = val }
            }
            let blobLen = sqlite3_column_bytes(stmt, 2)
            if blobLen > 0, let blobPtr = sqlite3_column_blob(stmt, 2) {
                encryptedData = Data(bytes: blobPtr, count: Int(blobLen))
            }
        }
        return (plainValue, encryptedData)
    }

    // MARK: - Claude API Calls

    /// The browser's last active org wins when it is still in the list; otherwise the first
    /// org with chat capability (then the first org at all).
    static func selectOrganization(from orgs: [[String: Any]], preferredOrgId: String?) -> String? {
        if let preferred = preferredOrgId?.lowercased(),
           let match = orgs.first(where: { ($0["uuid"] as? String)?.lowercased() == preferred }) {
            return match["uuid"] as? String
        }
        let selected = orgs.first(where: {
            let caps = $0["capabilities"] as? [String] ?? []
            return caps.contains("chat")
        }) ?? orgs.first
        return selected?["uuid"] as? String
    }

    /// GET /api/organizations → the browser's active org, else first org with chat capability.
    private func fetchOrgId(sessionKey: String, preferredOrgId: String?) async throws -> String {
        let url = URL(string: "\(Self.baseURL)/organizations")!
        let request = makeRequest(url: url, sessionKey: sessionKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCookiesError.parsingFailed("No HTTP response")
        }
        switch http.statusCode {
        case 200: break
        default: throw ClaudeCookiesError.forHTTPFailure(http)
        }
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClaudeCookiesError.parsingFailed("Cannot parse organizations list")
        }
        guard let uuid = Self.selectOrganization(from: orgs, preferredOrgId: preferredOrgId) else {
            throw ClaudeCookiesError.parsingFailed("No organization found")
        }
        return uuid
    }

    /// GET /api/organizations/{orgId}/usage → five_hour + seven_day windows.
    private func fetchUsage(orgId: String, sessionKey: String) async throws -> UsageSnapshot {
        let url = URL(string: "\(Self.baseURL)/organizations/\(orgId)/usage")!
        let request = makeRequest(url: url, sessionKey: sessionKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCookiesError.parsingFailed("No HTTP response")
        }
        switch http.statusCode {
        case 200: break
        default: throw ClaudeCookiesError.forHTTPFailure(http)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCookiesError.parsingFailed("Cannot parse usage response")
        }
        return parseUsageSnapshot(json: json)
    }

    private func parseUsageSnapshot(json: [String: Any]) -> UsageSnapshot {
        let sessionWindow = Self.parseWindowSnapshot(from: json["five_hour"] as? [String: Any], durationHours: 5)
        let weeklyWindow = Self.parseWindowSnapshot(from: json["seven_day"] as? [String: Any], durationHours: 168)

        return UsageSnapshot(
            provider: .claude,
            generatedAt: Date(),
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            totalEventsInPeriod: 0
        )
    }

    /// Maps a usage window dict `{ utilization: Number (0–100), resets_at: String? }` → WindowSnapshot.
    /// Important: `0` is a real authoritative value (100% left), not unknown.
    static func parseWindowSnapshot(from dict: [String: Any]?, durationHours: Int) -> WindowSnapshot {
        guard let dict else {
            return WindowSnapshot(durationHours: durationHours, tokensUsed: 0, costUSD: 0, percentUsed: nil, resetAt: nil, percentSource: .unknown)
        }

        let percentUsed = utilizationFraction(from: dict["utilization"])

        var resetAt: Date?
        if let resetsAtStr = dict["resets_at"] as? String {
            resetAt = parseISO8601(resetsAtStr)
        }
        return WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: 0,
            costUSD: 0,
            percentUsed: percentUsed,
            resetAt: resetAt,
            percentSource: percentUsed == nil ? .unknown : .authoritative
        )
    }

    static func utilizationFraction(from raw: Any?) -> Double? {
        let rawPercent: Double?
        switch raw {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            rawPercent = number.doubleValue
        case let string as String:
            rawPercent = Double(string)
        case let double as Double:
            rawPercent = double
        case let int as Int:
            rawPercent = Double(int)
        default:
            rawPercent = nil
        }
        guard let rawPercent, rawPercent.isFinite else { return nil }
        return min(max(rawPercent / 100.0, 0.0), 1.0)
    }

    /// Fetches account email from GET /api/account (best-effort, never throws).
    private func fetchAccountEmail(orgId: String, sessionKey: String) async -> String? {
        guard let url = URL(string: "\(Self.baseURL)/account") else { return nil }
        let request = makeRequest(url: url, sessionKey: sessionKey)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String
        else { return nil }
        return email
    }

    // MARK: - Helpers

    private func makeRequest(url: URL, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        #if DEBUG
        let masked = String(sessionKey.prefix(4)) + "..."
        _ = masked
        #endif
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(UUID().uuidString, forHTTPHeaderField: "anthropic-anonymous-id")
        request.timeoutInterval = 15
        return request
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
