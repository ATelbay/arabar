import Foundation
import CommonCrypto
import SQLite3
import os.log

private let chromiumLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-chromium-expiry")

// MARK: - Shared decrypt error

/// Errors thrown by ChromiumCookieDB.decryptChromeCookieBlob.
enum ChromiumDecryptError: Error {
    case invalidPrefix
    case decryptionFailed(OSStatus)
    case invalidPlaintext
}

enum ChromiumCookieDB {

    /// Returns expiry Date for the named cookie matching any of the given hosts,
    /// scanning all profiles under the browser's user data root.
    /// Returns nil if not found, session cookie (expires_utc == 0), or any error.
    static func cookieExpiry(browser: BrowserSource, cookieName: String, hosts: [String]) -> Date? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root: String
        switch browser {
        case .chrome:
            root = "\(home)/Library/Application Support/Google/Chrome"
        case .brave:
            root = "\(home)/Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge:
            root = "\(home)/Library/Application Support/Microsoft Edge"
        case .safari:
            return nil
        }

        let paths = profileCookiesPaths(underRoot: root)
        for path in paths {
            if let expiry = cookieExpiry(dbPath: path, cookieName: cookieName, hosts: hosts) {
                return expiry
            }
        }
        return nil
    }

    // MARK: - Profile enumeration

    /// Returns all existing Cookies DB paths under a Chromium User Data root (Default first, then Profile N in order).
    static func profileCookiesPaths(underRoot root: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        func appendProfile(_ profile: String) {
            // Chromium versions/platforms use either location; prefer Network when present.
            for suffix in ["Network/Cookies", "Cookies"] {
                let path = "\(root)/\(profile)/\(suffix)"
                if fm.fileExists(atPath: path) { results.append(path); return }
            }
        }
        appendProfile("Default")
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return results }
        let profileDirs = entries
            .filter { $0.hasPrefix("Profile ") && $0.dropFirst(8).allSatisfy(\.isNumber) }
            .sorted { a, b in
                let na = Int(a.dropFirst(8)) ?? 0
                let nb = Int(b.dropFirst(8)) ?? 0
                return na < nb
            }
        for dir in profileDirs {
            appendProfile(dir)
        }
        return results
    }

    // MARK: - Single DB query

    private static func cookieExpiry(dbPath: String, cookieName: String, hosts: [String]) -> Date? {
        guard let tmpURL = try? snapshotToTemp(dbPath) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
            sqlite3_close(db)
            debugLog(chromiumLog, "SQLite open failed: \(dbPath)")
            return nil
        }
        defer { sqlite3_close(db) }

        // Build host list: each host + leading-dot variant
        var hostSet: [String] = []
        for h in hosts {
            hostSet.append(h)
            if !h.hasPrefix(".") { hostSet.append(".\(h)") }
        }
        hostSet = Array(Set(hostSet))

        let placeholders = hostSet.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT expires_utc FROM cookies WHERE name = ? AND host_key IN (\(placeholders)) ORDER BY expires_utc DESC LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog(chromiumLog, "SQLite prepare failed for: \(dbPath)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, cookieName, -1, transient)
        for (i, host) in hostSet.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), host, -1, transient)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            debugLog(chromiumLog, "No matching cookie '\(cookieName)' in \(dbPath)")
            return nil
        }

        let expiresUtc = sqlite3_column_int64(stmt, 0)
        guard expiresUtc > 0 else {
            debugLog(chromiumLog, "Session cookie (expires_utc=0) '\(cookieName)' in \(dbPath)")
            return nil
        }

        // WebKit epoch: microseconds since 1601-01-01
        let unixSeconds = Double(expiresUtc) / 1_000_000 - 11_644_473_600
        let date = Date(timeIntervalSince1970: unixSeconds)
        debugLog(chromiumLog, "Cookie '\(cookieName)' expires at \(date) (from \(dbPath))")
        return date
    }

    // MARK: - Shared helpers (used by ClaudeCookiesReader + OpenAICookiesReader)

    /// Reads the schema version from a Cookies DB meta table.
    /// Chrome 130+ (DB schema version ≥ 24) prepends a 32-byte SHA256(host_key) to each plaintext cookie value.
    static func readCookieDBVersion(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        if let raw = sqlite3_column_text(stmt, 0) {
            return Int(String(cString: raw)) ?? 0
        }
        return 0
    }

    /// Decrypts a Chromium AES-128-CBC cookie blob.
    /// Checks for "v10"/"v11" prefix and strips it; if prefix is neither, treats entire blob as ciphertext.
    /// IV = 16 space characters (0x20). PKCS7 padding.
    /// When `hasHashPrefix` is true (DB version ≥ 24), drops the leading 32-byte SHA256(host_key) from plaintext.
    static func decryptChromeCookieBlob(_ data: Data, key: Data, hasHashPrefix: Bool) throws -> String {
        guard data.count > 3 else { throw ChromiumDecryptError.invalidPrefix }
        guard key.count == kCCKeySizeAES128 else { throw ChromiumDecryptError.invalidPlaintext }
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

        guard status == kCCSuccess else {
            throw ChromiumDecryptError.decryptionFailed(status)
        }
        outputBuf = outputBuf.prefix(decryptedLen)
        if hasHashPrefix {
            guard outputBuf.count >= 32 else { throw ChromiumDecryptError.invalidPlaintext }
            outputBuf = outputBuf.dropFirst(32)
        }
        guard let plaintext = String(data: outputBuf, encoding: .utf8) else {
            throw ChromiumDecryptError.invalidPlaintext
        }
        return plaintext
    }

    // MARK: - Consistent SQLite snapshot

    enum SnapshotError: Error { case sqlite(Int32) }

    /// SQLite's backup API includes committed WAL pages and takes a consistent snapshot.
    /// Copying only the main file loses recently refreshed cookies while the browser is open.
    static func snapshotToTemp(_ path: String) throws -> URL {
        var source: OpaquePointer?
        let sourceStatus = sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil)
        guard sourceStatus == SQLITE_OK, let source else {
            sqlite3_close(source)
            throw SnapshotError.sqlite(sourceStatus)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 1000)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arabar_\(UUID().uuidString).db")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: tmp) }
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }
        var destination: OpaquePointer?
        let destinationStatus = sqlite3_open_v2(tmp.path, &destination, SQLITE_OPEN_READWRITE, nil)
        guard destinationStatus == SQLITE_OK, let destination else {
            sqlite3_close(destination)
            throw SnapshotError.sqlite(destinationStatus)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SnapshotError.sqlite(sqlite3_errcode(destination))
        }
        let stepStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw SnapshotError.sqlite(stepStatus == SQLITE_DONE ? finishStatus : stepStatus)
        }
        // Ensure the returned snapshot is a single self-contained file.
        let journalStatus = sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        guard journalStatus == SQLITE_OK else { throw SnapshotError.sqlite(journalStatus) }
        succeeded = true
        return tmp
    }

    static func withTempCopy<T>(of sourcePath: String, _ body: (URL) throws -> T) throws -> T {
        let tmpURL = try snapshotToTemp(sourcePath)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        return try body(tmpURL)
    }
}
