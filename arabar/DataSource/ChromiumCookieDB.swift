import Foundation
import SQLite3
import os.log

private let chromiumLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-chromium-expiry")

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

    private static func profileCookiesPaths(underRoot root: String) -> [String] {
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

    // MARK: - Single DB query

    private static func cookieExpiry(dbPath: String, cookieName: String, hosts: [String]) -> Date? {
        guard let tmpURL = copyToTemp(dbPath) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
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

    // MARK: - Temp copy (avoids DB lock while browser is running)

    private static func copyToTemp(_ path: String) -> URL? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arabar_expiry_\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(atPath: path, toPath: tmp.path)
            return tmp
        } catch {
            debugLog(chromiumLog, "Failed to copy DB \(path): \(error)")
            return nil
        }
    }
}
