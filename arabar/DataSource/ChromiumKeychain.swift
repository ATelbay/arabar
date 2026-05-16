import Foundation
import Security
import CommonCrypto
import os.log

private let keychainLog = OSLog(subsystem: "com.arystantelbay.arabar", category: "cookies-chromium-keychain")

/// Shared Chromium Safe Storage key derivation helpers used by all Chromium-family cookie readers.
enum ChromiumKeychain {

    /// Reads all "Chrome/Brave/Edge Safe Storage" entries from the macOS Keychain.
    /// Combines native Keychain API (with diagnostic probe) and `/usr/bin/security` CLI fallback.
    /// Returns all candidate password Data values so callers can try each in turn.
    static func readAllCandidateKeys(service: String, account: String) -> [Data] {
        if let nativeCandidates = try? readKeychainNativeAll(service: service, account: account),
           !nativeCandidates.isEmpty {
            return nativeCandidates
        }
        if let cliData = try? readKeychainViaSecurityCLI(service: service, account: account) {
            return [cliData]
        }
        return []
    }

    /// Derives a 16-byte AES-128 key from a password Data using PBKDF2-SHA1.
    /// Salt = "saltysalt", iterations = 1003, output length = 16 bytes.
    /// Accepts Data directly to avoid an unnecessary UTF-8 round-trip.
    static func deriveAESKey(from passwordData: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(repeating: 0, count: 16)
        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
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
        guard status == kCCSuccess else { return nil }
        return derivedKey
    }

    // MARK: - Private helpers

    /// Enumerates ALL matching Keychain entries and returns their non-empty password Data values.
    /// Performs a diagnostic probe (service-only) first for better logging, then fetches data with account filter.
    private static func readKeychainNativeAll(service: String, account: String) throws -> [Data] {
        // Probe by SERVICE only (no account filter) to see ALL entries with this service
        let probeQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll
        ]
        var probeResult: CFTypeRef?
        let probeStatus = SecItemCopyMatching(probeQuery as CFDictionary, &probeResult)
        debugLog(keychainLog, "probe (service=\(service)): status=\(Int(probeStatus))")
        if probeStatus == errSecSuccess, let attrs = probeResult as? [[String: Any]] {
            for (i, dict) in attrs.enumerated() {
                let acct   = dict[kSecAttrAccount as String] as? String ?? "?"
                let label  = dict[kSecAttrLabel as String] as? String ?? "?"
                let creator = (dict[kSecAttrCreator as String] as? Int).map { String(format: "0x%08x", $0) } ?? "?"
                debugLog(keychainLog, "probe entry #\(i): acct=\(acct), label=\(label), creator=\(creator)")
            }
        } else if probeStatus == errSecSuccess, let single = probeResult as? [String: Any] {
            let acct  = single[kSecAttrAccount as String] as? String ?? "?"
            let label = single[kSecAttrLabel as String] as? String ?? "?"
            debugLog(keychainLog, "probe single entry: acct=\(acct), label=\(label)")
        }

        // Actual data fetch — service + account filter
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // Propagate so callers can fall through to CLI
            throw _KeychainError.accessDenied
        }
        if let array = result as? [Data] {
            return array.filter { !$0.isEmpty }
        }
        if let single = result as? Data, !single.isEmpty {
            return [single]
        }
        return []
    }

    private static func readKeychainViaSecurityCLI(service: String, account: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw _KeychainError.accessDenied
        }
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw _KeychainError.accessDenied }
        return Data(trimmed.utf8)
    }

    // Internal error — callers never see this; they receive empty array from readAllCandidateKeys.
    private enum _KeychainError: Error { case accessDenied }
}
