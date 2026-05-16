import Foundation
import Security
import SQLite3
import CommonCrypto
import os.log

private let openaiLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-openai")

// MARK: - Browser source

/// Supported browser sources for OpenAI cookie reading.
/// NOTE: If BrowserSource is also defined in ClaudeCookiesReader (parallel T10 agent),
/// rename this to OpenAIBrowserSource to avoid collision.
// TODO: share with ClaudeCookiesReader once both readers stabilise
enum OpenAIBrowserSource: String {
    case safari
    case chrome
    case brave
    case edge
}

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

        let source = OpenAIBrowserSource(
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
            let source = OpenAIBrowserSource(
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
        } catch SafariCookiesError.fileNotFound {
            throw OpenAICookiesError.cookiesNotFound
        } catch SafariCookiesError.accessDenied {
            throw OpenAICookiesError.accessDenied
        } catch SafariCookiesError.invalidFormat(let msg) {
            throw OpenAICookiesError.parsingFailed(msg)
        }
    }

    private func extractCookieHeader(from source: OpenAIBrowserSource) throws -> String {
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

    /// Returns existing Cookies paths for all valid profiles under a Chromium User Data root.
    private func profileCookiesPaths(underRoot root: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        let defaultPath = "\(root)/Default/Cookies"
        if fm.fileExists(atPath: defaultPath) { results.append(defaultPath) }

        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return results }
        let profileDirs = entries
            .filter { $0.hasPrefix("Profile ") && $0.dropFirst(8).allSatisfy(\.isNumber) }
            .sorted { a, b in
                let na = Int(a.dropFirst(8)) ?? 0
                let nb = Int(b.dropFirst(8)) ?? 0
                return na < nb
            }
        for dir in profileDirs {
            let p = "\(root)/\(dir)/Cookies"
            if fm.fileExists(atPath: p) { results.append(p) }
        }
        return results
    }

    private func chromeProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Google/Chrome")
    }

    private func braveProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser")
    }

    private func edgeProfileCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Microsoft Edge")
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
        // Always copy — Chrome may lock the file
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arabar_openai_cookies_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.copyItem(atPath: path, toPath: tmp.path)
        } catch {
            throw OpenAICookiesError.cookiesNotFound
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw OpenAICookiesError.cookiesNotFound
        }
        defer { sqlite3_close(db) }
        let dbVersion = readCookieDBVersion(db: db!)
        let hasHashPrefix = dbVersion >= 24
        debugLog(openaiLog, "DB meta version=\(dbVersion), hasHashPrefix=\(hasHashPrefix ? "YES" : "NO")")
        return try extractChromeCookies(db: db!, aesKeys: aesKeys, hasHashPrefix: hasHashPrefix)
    }

    /// Reads the schema version from the Cookies DB meta table.
    /// Chrome 130+ (DB version ≥ 24) prepends a 32-byte SHA256(host_key) to each cookie value before encryption.
    private func readCookieDBVersion(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        if let raw = sqlite3_column_text(stmt, 0) {
            return Int(String(cString: raw)) ?? 0
        }
        return 0
    }

    private func extractChromeCookies(db: OpaquePointer, aesKeys: [Data], hasHashPrefix: Bool) throws -> String {
        // Match exact prefix; ORDER BY name gives .0, .1, … in order
        let sql = """
            SELECT name, value, encrypted_value
            FROM cookies
            WHERE host_key LIKE '%chatgpt.com%'
            AND name LIKE '\(Self.sessionCookiePrefix)%'
            ORDER BY name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OpenAICookiesError.parsingFailed("SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

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
                            let plaintext = try decryptChromeValue(encData, key: key, hasHashPrefix: hasHashPrefix)
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
    /// key per non-empty password. Returns an array so callers can try each in turn.
    private func chromeAESKeys(account: String, service: String) throws -> [Data] {
        // Gather candidate password blobs — native API first, CLI fallback
        var passwordCandidates: [Data] = []

        if let nativeCandidates = try? readKeychainNativeAll(service: service, account: account),
           !nativeCandidates.isEmpty {
            passwordCandidates = nativeCandidates
        } else if let cliData = try? readKeychainViaSecurityCLI(service: service, account: account) {
            passwordCandidates = [cliData]
        }

        guard !passwordCandidates.isEmpty else {
            throw OpenAICookiesError.keychainAccessDenied
        }

        // Derive a 16-byte AES key for each candidate password
        var keys: [Data] = []
        for passwordData in passwordCandidates {
            guard let password = String(data: passwordData, encoding: .utf8) else { continue }
            if let key = try? pbkdf2Key(password: password) {
                keys.append(key)
            }
        }

        guard !keys.isEmpty else { throw OpenAICookiesError.decryptionFailed }
        return keys
    }

    /// Enumerates ALL matching Keychain entries and returns their non-empty password Data values.
    private func readKeychainNativeAll(service: String, account: String) throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw OpenAICookiesError.keychainAccessDenied
        }
        // kSecMatchLimitAll returns an array of Data when kSecReturnData is true
        if let array = result as? [Data] {
            return array.filter { !$0.isEmpty }
        }
        // Single result returned as plain Data
        if let single = result as? Data, !single.isEmpty {
            return [single]
        }
        return []
    }

    private func readKeychainViaSecurityCLI(service: String, account: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenAICookiesError.keychainAccessDenied
        }
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw OpenAICookiesError.keychainAccessDenied
        }
        return Data(trimmed.utf8)
    }

    /// Derives 16-byte AES key: PBKDF2-SHA1, salt="saltysalt", 1003 iterations.
    private func pbkdf2Key(password: String) throws -> Data {
        let salt = Data("saltysalt".utf8)
        let keyLen = 16
        var derivedKey = Data(repeating: 0, count: keyLen)
        let passData = Data(password.utf8)

        let status: Int32 = passData.withUnsafeBytes { passPtr in
            salt.withUnsafeBytes { saltPtr in
                derivedKey.withUnsafeMutableBytes { keyPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                        passData.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        keyLen
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw OpenAICookiesError.decryptionFailed }
        return derivedKey
    }

    // MARK: - AES-128-CBC decryption

    /// Decrypts a Chrome encrypted cookie value.
    /// Format (v10/v11 prefix): `v10` or `v11` + 3-byte prefix + AES-CBC ciphertext.
    private func decryptChromeValue(_ data: Data, key: Data, hasHashPrefix: Bool) throws -> String {
        guard data.count > 3 else { throw OpenAICookiesError.decryptionFailed }
        let prefix = String(data: data.prefix(3), encoding: .utf8) ?? ""
        let ciphertext: Data
        if prefix == "v10" || prefix == "v11" {
            ciphertext = data.dropFirst(3)
        } else {
            ciphertext = data
        }

        let iv = Data(repeating: 0x20, count: 16)

        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var outputBuf = Data(repeating: 0, count: outputCapacity)
        var decryptedLen = 0

        let status: CCCryptorStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                ciphertext.withUnsafeBytes { ctPtr in
                    outputBuf.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress!, key.count,
                            ivPtr.baseAddress!,
                            ctPtr.baseAddress!, ciphertext.count,
                            outPtr.baseAddress!, outputCapacity,
                            &decryptedLen
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw OpenAICookiesError.decryptionFailed }
        outputBuf = outputBuf.prefix(decryptedLen)
        if hasHashPrefix && outputBuf.count > 32 {
            outputBuf = outputBuf.dropFirst(32)
        }
        guard let plaintext = String(data: outputBuf, encoding: .utf8) else {
            throw OpenAICookiesError.decryptionFailed
        }
        return plaintext
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
        return WindowSnapshot(
            durationHours: hours,
            tokensUsed: 0,
            costUSD: 0,
            percentUsed: Double(s.usedPercent) / 100.0,
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
