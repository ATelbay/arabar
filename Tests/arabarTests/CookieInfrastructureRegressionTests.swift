import XCTest
import SQLite3
import Security
import CommonCrypto
@testable import arabar

final class CookieInfrastructureRegressionTests: XCTestCase {
    func testSnapshotIncludesCommittedUncheckpointedWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE cookies (value TEXT); INSERT INTO cookies VALUES ('fresh synthetic cookie');", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))

        var snapshotPath: String?
        try ChromiumCookieDB.withTempCopy(of: source.path) { snapshot in
            snapshotPath = snapshot.path
            var copy: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(snapshot.path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            defer { sqlite3_close(copy) }
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT value FROM cookies", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "fresh synthetic cookie")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(snapshotPath)))
    }

    func testProfileEnumerationSupportsNetworkLocationAndNumericOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["Default/Network/Cookies", "Profile 10/Cookies", "Profile 2/Network/Cookies"]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertEqual(ChromiumCookieDB.profileCookiesPaths(underRoot: root.path),
                       [paths[0], paths[2], paths[1]].map { root.appendingPathComponent($0).path })
    }

    func testSafariDomainMatchingRejectsLookalikesAndChildDomains() {
        XCTAssertTrue(SafariBinaryCookies.domain(".CLAUDE.ai", matches: "claude.ai"))
        for domain in ["evilclaude.ai", "claude.ai.evil.test", "sub.claude.ai"] {
            XCTAssertFalse(SafariBinaryCookies.domain(domain, matches: "claude.ai"))
        }
    }

    func testNextAuthRejectsMissingChunksAndAcceptsShortFinalChunk() throws {
        let reader = OpenAICookiesReader()
        let prefix = "__Secure-next-auth.session-token"
        XCTAssertEqual(try reader.assembleNextAuthCookieHeader(pairs: [(prefix + ".1", "b"), (prefix + ".0", "a")]),
                       prefix + ".0=a; " + prefix + ".1=b")
        XCTAssertThrowsError(try reader.assembleNextAuthCookieHeader(pairs: [(prefix + ".1", "b")]))
        XCTAssertThrowsError(try reader.assembleNextAuthCookieHeader(pairs: [(prefix + ".0", "a"), (prefix + ".2", "c")]))
        XCTAssertThrowsError(try reader.assembleNextAuthCookieHeader(pairs: [(prefix + ".foo", "a")]))
        XCTAssertThrowsError(try reader.assembleNextAuthCookieHeader(pairs: [(prefix + "unrelated", "a")]))
    }

    func testSchema24HashPrefixCannotBecomeCookieValue() throws {
        let key = Data(repeating: 7, count: 16)
        for count in [12, 32] {
            let blob = try encrypt(Data(repeating: 65, count: count), key: key)
            if count < 32 {
                XCTAssertThrowsError(try ChromiumCookieDB.decryptChromeCookieBlob(blob, key: key, hasHashPrefix: true))
            } else {
                XCTAssertEqual(try ChromiumCookieDB.decryptChromeCookieBlob(blob, key: key, hasHashPrefix: true), "")
            }
        }
        XCTAssertThrowsError(try ChromiumCookieDB.decryptChromeCookieBlob(Data("v10abc".utf8), key: Data(), hasHashPrefix: false))
    }

    func testCodexAuthReadsNestedTokensWithoutAccessingUserCredentials() throws {
        let data = Data(#"{"tokens":{"access_token":"synthetic","account_id":"account"},"last_refresh":"2026-09-01T00:00:00Z"}"#.utf8)
        let parsed = try XCTUnwrap(CodexAuth.parse(data: data))
        XCTAssertEqual(parsed.accessToken, "synthetic")
        XCTAssertEqual(parsed.accountId, "account")
        XCTAssertNil(parsed.expiresAt)
    }

    func testFailedKeychainUpdateDoesNotAttemptReplacement() {
        var didAdd = false
        XCTAssertThrowsError(try KeychainStore.set("synthetic", for: "test", update: { _, _ in errSecAuthFailed }, add: { _ in
            didAdd = true
            return errSecSuccess
        }))
        XCTAssertFalse(didAdd)
    }

    func testKeychainAddsOnlyWhenMissingAndDeleteIsIdempotent() throws {
        var didAdd = false
        try KeychainStore.set("synthetic", for: "test", update: { _, _ in errSecItemNotFound }, add: { _ in
            didAdd = true
            return errSecSuccess
        })
        XCTAssertTrue(didAdd)
        XCTAssertTrue(KeychainStore.delete(account: "test", deleteItem: { _ in errSecItemNotFound }))
        XCTAssertFalse(KeychainStore.delete(account: "test", deleteItem: { _ in errSecAuthFailed }))
    }

    func testBooleanUtilizationIsUnknown() {
        XCTAssertNil(ClaudeCookiesReader.utilizationFraction(from: NSNumber(value: true)))
        XCTAssertNil(ClaudeCookiesReader.utilizationFraction(from: false))
    }

    func testAccountHeaderUsesAccountClaimAndNeverUserID() {
        let payload = Data(#"{"sub":"user-synthetic","https://api.openai.com/auth":{"chatgpt_account_id":"workspace-synthetic"}}"#.utf8)
        let token = "header." + payload.base64EncodedString() + ".signature"
        XCTAssertEqual(OpenAICookiesReader.accountID(fromAccessToken: token), "workspace-synthetic")
        let userOnly = "header." + Data(#"{"sub":"user-synthetic"}"#.utf8).base64EncodedString() + ".signature"
        XCTAssertNil(OpenAICookiesReader.accountID(fromAccessToken: userOnly))
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: 16)
        let capacity = plaintext.count + 16
        var output = Data(count: capacity)
        var length = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { i in
                plaintext.withUnsafeBytes { p in
                    output.withUnsafeMutableBytes { o in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress, p.baseAddress, plaintext.count,
                                o.baseAddress, capacity, &length)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + output.prefix(length)
    }
}
