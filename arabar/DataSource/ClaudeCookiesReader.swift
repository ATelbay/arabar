import Foundation
import Security
import SQLite3
import CommonCrypto
import os.log

private let claudeLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-claude")

// MARK: - Public Types

enum BrowserSource: String, Codable, CaseIterable {
    case safari, chrome, brave, edge
}

enum ClaudeCookiesError: Error {
    case cookiesNotFound
    case browserUnsupported
    case decryptionFailed
    case accessDenied
    case httpError(Int)
    case parsingFailed(String)
    case disabled
    case appBoundEncryption
    case keychainAccessDenied
}

// MARK: - ClaudeCookiesReader

final class ClaudeCookiesReader {

    // MARK: - Constants

    private static let claudeDomain = "claude.ai"
    private static let sessionCookieName = "sessionKey"
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

        let sessionKey = try extractSessionKey(from: source)
        let orgId = try await fetchOrgId(sessionKey: sessionKey)
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
            let sessionKey = try extractSessionKey(from: source)
            let orgId = try await fetchOrgId(sessionKey: sessionKey)
            if let email = await fetchAccountEmail(orgId: orgId, sessionKey: sessionKey) {
                return "Logged in as \(email)"
            }
            return "Connected (org: \(orgId.prefix(8))…)"
        } catch ClaudeCookiesError.cookiesNotFound {
            return "No cookies — log in to claude.ai in \(source.rawValue.capitalized)"
        } catch ClaudeCookiesError.browserUnsupported {
            return "Browser \(source.rawValue) not yet supported (use Chrome/Brave/Edge)"
        } catch ClaudeCookiesError.keychainAccessDenied {
            return "Open Keychain Access.app, find 'Chrome Safe Storage', and add arabar to its Access Control list."
        } catch ClaudeCookiesError.decryptionFailed {
            return "Error: Cookie decryption failed"
        } catch ClaudeCookiesError.appBoundEncryption {
            return "Chrome App-Bound Encryption (v20) cookies not supported — try Safari or Chrome v126-"
        } catch ClaudeCookiesError.accessDenied {
            return "Error: Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access"
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
        } catch SafariCookiesError.fileNotFound {
            throw ClaudeCookiesError.cookiesNotFound
        } catch SafariCookiesError.accessDenied {
            throw ClaudeCookiesError.accessDenied
        } catch SafariCookiesError.invalidFormat(let msg) {
            throw ClaudeCookiesError.parsingFailed(msg)
        }
    }

    private func extractSessionKey(from source: BrowserSource) throws -> String {
        switch source {
        case .safari:
            let cookies = try mapSafariError {
                try SafariBinaryCookies.readCookies(matching: ["claude.ai"])
            }
            guard let sessionCookie = cookies.first(where: { $0.name == Self.sessionCookieName }) else {
                throw ClaudeCookiesError.cookiesNotFound
            }
            return sessionCookie.value
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

    /// Returns all existing Cookies DB paths under a Chromium User Data root.
    private func profileCookiesPaths(underRoot root: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        // "Default" always first, then "Profile N" in numeric order
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

    private func chromeCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Google/Chrome")
    }

    private func braveCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/BraveSoftware/Brave-Browser")
    }

    private func edgeCookiesPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profileCookiesPaths(underRoot: "\(home)/Library/Application Support/Microsoft Edge")
    }

    // MARK: - Multi-profile extraction

    /// Tries each profile DB in order; returns the first that contains the cookie.
    private func extractFromProfiles(
        paths: [String],
        safeStorageService: String,
        safeStorageAccount: String
    ) throws -> String {
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
            } catch ClaudeCookiesError.cookiesNotFound {
                lastError = ClaudeCookiesError.cookiesNotFound
                continue
            } catch {
                // Propagate decryption / app-bound errors immediately
                throw error
            }
        }
        throw lastError
    }

    // MARK: - Chrome / Chromium Cookie Decryption

    /// Reads the Chromium-family SQLite cookies DB and returns the `sessionKey` value for claude.ai.
    private func extractChromeSessionKey(
        dbPath: String,
        safeStorageService: String,
        safeStorageAccount: String
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ClaudeCookiesError.cookiesNotFound
        }

        // Copy DB to temp — Chrome may lock the file
        let tmpPath = NSTemporaryDirectory() + "arabar_cookies_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmpPath)
        } catch {
            throw ClaudeCookiesError.cookiesNotFound
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ClaudeCookiesError.cookiesNotFound
        }
        defer { sqlite3_close(db) }

        let dbVersion = readCookieDBVersion(db: db!)
        let hasHashPrefix = dbVersion >= 24
        debugLog(claudeLog, "DB meta version=\(dbVersion), hasHashPrefix=\(hasHashPrefix ? "YES" : "NO")")

        let sql = """
            SELECT name, value, encrypted_value
            FROM cookies
            WHERE host_key LIKE '%\(Self.claudeDomain)%'
            AND name = '\(Self.sessionCookieName)'
            LIMIT 1;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClaudeCookiesError.parsingFailed("SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

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

        // Row not found at all → not found
        if plainValue == nil && encryptedData == nil {
            throw ClaudeCookiesError.cookiesNotFound
        }

        if let plain = plainValue, !plain.isEmpty {
            return plain
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

        let aesKeys = try chromeSafeStorageKey(service: safeStorageService, account: safeStorageAccount)
        let keylens = aesKeys.map { $0.count }.map(String.init).joined(separator: ",")
        debugLog(claudeLog, "keychain candidates: \(aesKeys.count), keylens=[\(keylens)]")
        for (idx, key) in aesKeys.enumerated() {
            do {
                let decrypted = try decryptChromeCookie(encrypted: encrypted, key: key, hasHashPrefix: hasHashPrefix)
                let head = String(decrypted.prefix(8))
                let valid = decrypted.hasPrefix("sk-ant-")
                debugLog(claudeLog, "key #\(idx) → decrypt OK, len=\(decrypted.count), head=\(head), valid=\(valid ? "YES" : "NO")")
                if valid { return decrypted }
            } catch {
                debugLog(claudeLog, "key #\(idx) → decrypt FAILED: \(error)")
            }
        }
        throw ClaudeCookiesError.decryptionFailed
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

    /// Reads all "Chrome Safe Storage" entries from the macOS Keychain and derives one AES-128 key per
    /// non-empty password. Returns an array so callers can try each in turn.
    private func chromeSafeStorageKey(service: String, account: String) throws -> [Data] {
        // Gather all candidate password blobs — native API first, CLI fallback
        var passwordCandidates: [Data] = []

        if let nativeCandidates = try? readKeychainNativeAll(service: service, account: account),
           !nativeCandidates.isEmpty {
            passwordCandidates = nativeCandidates
        } else if let cliData = try? readKeychainViaSecurityCLI(service: service, account: account) {
            passwordCandidates = [cliData]
        }

        guard !passwordCandidates.isEmpty else {
            throw ClaudeCookiesError.keychainAccessDenied
        }

        let pwLens = passwordCandidates.map { $0.count }.map(String.init).joined(separator: ",")
        debugLog(claudeLog, "password candidates: \(passwordCandidates.count), pwlens=[\(pwLens)]")

        // Derive a 16-byte AES key via PBKDF2-SHA1 for each candidate password
        let salt = Data("saltysalt".utf8)
        var keys: [Data] = []
        for passwordData in passwordCandidates {
            var derivedKey = Data(repeating: 0, count: 16)
            let pbkdf2Status = derivedKey.withUnsafeMutableBytes { derivedBytes in
                salt.withUnsafeBytes { saltBytes in
                    passwordData.withUnsafeBytes { passwordBytes in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                            passwordData.count,
                            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                            1003,
                            derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            16
                        )
                    }
                }
            }
            if pbkdf2Status == kCCSuccess {
                keys.append(derivedKey)
            }
        }

        guard !keys.isEmpty else { throw ClaudeCookiesError.decryptionFailed }
        return keys
    }

    /// Enumerates ALL matching Keychain entries and returns their non-empty password Data values.
    private func readKeychainNativeAll(service: String, account: String) throws -> [Data] {
        // First — search by SERVICE only (no account filter) to see ALL entries with this service
        let probeQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:      kSecMatchLimitAll
        ]
        var probeResult: CFTypeRef?
        let probeStatus = SecItemCopyMatching(probeQuery as CFDictionary, &probeResult)
        debugLog(claudeLog, "probe (service=\(service)): status=\(Int(probeStatus))")
        if probeStatus == errSecSuccess, let attrs = probeResult as? [[String: Any]] {
            for (i, dict) in attrs.enumerated() {
                let acct = dict[kSecAttrAccount as String] as? String ?? "?"
                let label = dict[kSecAttrLabel as String] as? String ?? "?"
                let creator = (dict[kSecAttrCreator as String] as? Int).map { String(format: "0x%08x", $0) } ?? "?"
                debugLog(claudeLog, "probe entry #\(i): acct=\(acct), label=\(label), creator=\(creator)")
            }
        } else if probeStatus == errSecSuccess, let single = probeResult as? [String: Any] {
            let acct = single[kSecAttrAccount as String] as? String ?? "?"
            let label = single[kSecAttrLabel as String] as? String ?? "?"
            debugLog(claudeLog, "probe single entry: acct=\(acct), label=\(label)")
        }

        // Now actual data fetch (service + account filter)
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
            throw ClaudeCookiesError.keychainAccessDenied
        }
        if let array = result as? [Data] {
            return array.filter { !$0.isEmpty }
        }
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
            throw ClaudeCookiesError.keychainAccessDenied
        }
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw ClaudeCookiesError.keychainAccessDenied
        }
        return Data(trimmed.utf8)
    }

    /// Decrypts a Chromium-encrypted cookie blob.
    /// Format: prefix "v10" (3 bytes) + AES-128-CBC ciphertext, IV = 16 space characters.
    /// Chrome 130+ (DB schema version ≥ 24) prepends a 32-byte SHA256(host_key) to plaintext.
    private func decryptChromeCookie(encrypted: Data, key: Data, hasHashPrefix: Bool) throws -> String {
        let prefixLen = 3
        guard encrypted.count > prefixLen else {
            throw ClaudeCookiesError.decryptionFailed
        }
        let ciphertext = encrypted.dropFirst(prefixLen)
        let iv = Data(repeating: 0x20, count: 16) // 16 space characters

        let outputLen = ciphertext.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: outputLen)
        var numBytesDecrypted = 0

        let ciphertextArray = [UInt8](ciphertext)
        let keyArray = [UInt8](key)
        let ivArray = [UInt8](iv)

        let cryptStatus: CCCryptorStatus = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            keyArray, keyArray.count,
            ivArray,
            ciphertextArray, ciphertextArray.count,
            &decryptedBytes, outputLen,
            &numBytesDecrypted
        )

        guard cryptStatus == kCCSuccess else {
            debugLog(claudeLog, "CCCrypt FAILED: status=\(Int(cryptStatus)), ctlen=\(ciphertextArray.count), keylen=\(keyArray.count)")
            throw ClaudeCookiesError.decryptionFailed
        }
        var decryptedData = Data(decryptedBytes.prefix(numBytesDecrypted))
        if hasHashPrefix && decryptedData.count > 32 {
            decryptedData = decryptedData.dropFirst(32)
        }

        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            debugLog(claudeLog, "UTF-8 decode FAILED (decrypted bytes are not valid UTF-8 → wrong AES key)")
            throw ClaudeCookiesError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Claude API Calls

    /// GET /api/organizations → returns first org UUID with chat capability.
    private func fetchOrgId(sessionKey: String) async throws -> String {
        let url = URL(string: "\(Self.baseURL)/organizations")!
        let request = makeRequest(url: url, sessionKey: sessionKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCookiesError.parsingFailed("No HTTP response")
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ClaudeCookiesError.httpError(http.statusCode)
        default: throw ClaudeCookiesError.httpError(http.statusCode)
        }
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClaudeCookiesError.parsingFailed("Cannot parse organizations list")
        }
        let selected = orgs.first(where: {
            let caps = $0["capabilities"] as? [String] ?? []
            return caps.contains("chat")
        }) ?? orgs.first
        guard let org = selected, let uuid = org["uuid"] as? String else {
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
        case 401, 403: throw ClaudeCookiesError.httpError(http.statusCode)
        default: throw ClaudeCookiesError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCookiesError.parsingFailed("Cannot parse usage response")
        }
        return parseUsageSnapshot(json: json)
    }

    private func parseUsageSnapshot(json: [String: Any]) -> UsageSnapshot {
        let sessionWindow = parseWindow(from: json["five_hour"] as? [String: Any], durationHours: 5)
        let weeklyWindow = parseWindow(from: json["seven_day"] as? [String: Any], durationHours: 168)

        return UsageSnapshot(
            provider: .claude,
            generatedAt: Date(),
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            totalEventsInPeriod: 0
        )
    }

    /// Maps a usage window dict `{ utilization: Int (0–100), resets_at: String? }` → WindowSnapshot.
    private func parseWindow(from dict: [String: Any]?, durationHours: Int) -> WindowSnapshot {
        guard let dict = dict else {
            return WindowSnapshot(durationHours: durationHours, tokensUsed: 0, costUSD: 0, percentUsed: nil, resetAt: nil, percentSource: .authoritative)
        }
        let utilizationRaw = dict["utilization"] as? Int ?? 0
        let percentUsed = Double(utilizationRaw) / 100.0

        var resetAt: Date?
        if let resetsAtStr = dict["resets_at"] as? String {
            resetAt = parseISO8601(resetsAtStr)
        }
        return WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: 0,
            costUSD: 0,
            percentUsed: utilizationRaw > 0 ? percentUsed : nil,
            resetAt: resetAt,
            percentSource: .authoritative
        )
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

    private func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
