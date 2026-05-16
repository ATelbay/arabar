import Foundation

// MARK: - Public Types

enum SafariCookiesError: Error {
    case fileNotFound
    case accessDenied
    case invalidFormat(String)
}

struct SafariCookie {
    let domain: String
    let name: String
    let value: String
    let path: String
    let expiry: Date?
    let isSecure: Bool
}

// MARK: - Parser

enum SafariBinaryCookies {

    private static let maxFileSize = 100 * 1024 * 1024  // 100 MB cap
    private static let appleEpochOffset: TimeInterval = 978307200  // seconds from Unix epoch to 2001-01-01

    static func readCookies(matching hostMatches: [String]) throws -> [SafariCookie] {
        let cookiesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Cookies/Cookies.binarycookies")

        guard FileManager.default.fileExists(atPath: cookiesURL.path) else {
            throw SafariCookiesError.fileNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: cookiesURL)
        } catch let nsError as NSError where nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM) {
            throw SafariCookiesError.accessDenied
        } catch let nsError as NSError where nsError.code == NSFileReadNoPermissionError {
            throw SafariCookiesError.accessDenied
        }

        guard data.count <= maxFileSize else {
            throw SafariCookiesError.invalidFormat("File exceeds 100 MB limit")
        }

        return try parse(data: data, matching: hostMatches)
    }

    // MARK: - Binary Parser

    private static func parse(data: Data, matching hostMatches: [String]) throws -> [SafariCookie] {
        var offset = 0

        // Magic: "cook"
        guard data.count >= 8 else {
            throw SafariCookiesError.invalidFormat("File too small")
        }
        let magic = data.subdata(in: 0..<4)
        guard magic == Data("cook".utf8) else {
            throw SafariCookiesError.invalidFormat("Bad magic bytes")
        }
        offset = 4

        let pageCount = Int(readUInt32BE(data: data, offset: offset))
        offset += 4

        guard pageCount > 0, data.count >= offset + pageCount * 4 else {
            throw SafariCookiesError.invalidFormat("Invalid page count \(pageCount)")
        }

        // Read page sizes
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            pageSizes.append(Int(readUInt32BE(data: data, offset: offset)))
            offset += 4
        }

        // Parse each page
        var results: [SafariCookie] = []
        for size in pageSizes {
            guard offset + size <= data.count else {
                throw SafariCookiesError.invalidFormat("Page extends beyond file")
            }
            let pageData = data.subdata(in: offset..<(offset + size))
            let cookies = try parsePage(pageData: pageData)
            for cookie in cookies {
                if hostMatches.contains(where: { cookie.domain.contains($0) }) {
                    results.append(cookie)
                }
            }
            offset += size
        }

        return results
    }

    private static func parsePage(pageData: Data) throws -> [SafariCookie] {
        guard pageData.count >= 8 else {
            throw SafariCookiesError.invalidFormat("Page too small")
        }

        // Page header tag: 0x00000100
        let tag = readUInt32BE(data: pageData, offset: 0)
        guard tag == 0x00000100 else {
            throw SafariCookiesError.invalidFormat("Bad page header tag: \(String(tag, radix: 16))")
        }

        let cookieCount = Int(readUInt32LE(data: pageData, offset: 4))
        guard cookieCount >= 0, pageData.count >= 8 + cookieCount * 4 else {
            throw SafariCookiesError.invalidFormat("Invalid cookie count \(cookieCount) in page")
        }

        // Read cookie offsets (LE, relative to page start)
        var cookieOffsets: [Int] = []
        for i in 0..<cookieCount {
            cookieOffsets.append(Int(readUInt32LE(data: pageData, offset: 8 + i * 4)))
        }

        var cookies: [SafariCookie] = []
        for cookieOffset in cookieOffsets {
            guard cookieOffset < pageData.count else {
                throw SafariCookiesError.invalidFormat("Cookie offset \(cookieOffset) out of bounds")
            }
            if let cookie = try parseCookieRecord(pageData: pageData, recordOffset: cookieOffset) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    private static func parseCookieRecord(pageData: Data, recordOffset: Int) throws -> SafariCookie? {
        let base = recordOffset
        guard base + 56 <= pageData.count else {
            throw SafariCookiesError.invalidFormat("Cookie record header truncated at offset \(base)")
        }

        let recordSize   = Int(readUInt32LE(data: pageData, offset: base + 0))
        guard base + recordSize <= pageData.count else {
            throw SafariCookiesError.invalidFormat("Cookie record size \(recordSize) exceeds page at offset \(base)")
        }

        let flags        = readUInt32LE(data: pageData, offset: base + 8)
        let domainOff    = Int(readUInt32LE(data: pageData, offset: base + 16))
        let nameOff      = Int(readUInt32LE(data: pageData, offset: base + 20))
        let pathOff      = Int(readUInt32LE(data: pageData, offset: base + 24))
        let valueOff     = Int(readUInt32LE(data: pageData, offset: base + 28))

        // Dates at base+40 (expiry) and base+48 (creation), Float64 LE, Apple epoch
        let expiry   = readFloat64LE(data: pageData, offset: base + 40)
        let expiryDate: Date? = expiry > 0
            ? Date(timeIntervalSince1970: expiry + appleEpochOffset)
            : nil

        guard let domain = readNullTerminatedString(pageData: pageData, base: base, fieldOffset: domainOff, recordSize: recordSize),
              let name   = readNullTerminatedString(pageData: pageData, base: base, fieldOffset: nameOff,   recordSize: recordSize),
              let path   = readNullTerminatedString(pageData: pageData, base: base, fieldOffset: pathOff,   recordSize: recordSize),
              let value  = readNullTerminatedString(pageData: pageData, base: base, fieldOffset: valueOff,  recordSize: recordSize)
        else {
            throw SafariCookiesError.invalidFormat("String offset out of bounds in cookie record at \(base)")
        }

        let isSecure = (flags & 0x1) != 0

        return SafariCookie(domain: domain, name: name, value: value, path: path, expiry: expiryDate, isSecure: isSecure)
    }

    // MARK: - Read helpers

    private static func readUInt32BE(data: Data, offset: Int) -> UInt32 {
        let slice = data[offset..<(offset + 4)]
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private static func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        let slice = data[offset..<(offset + 4)]
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    private static func readFloat64LE(data: Data, offset: Int) -> Double {
        let slice = data[offset..<(offset + 8)]
        let bits = slice.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return Double(bitPattern: bits)
    }

    private static func readNullTerminatedString(
        pageData: Data,
        base: Int,
        fieldOffset: Int,
        recordSize: Int
    ) -> String? {
        let absOffset = base + fieldOffset
        guard fieldOffset > 0, absOffset < base + recordSize, absOffset < pageData.count else {
            return nil
        }
        // Find null terminator within record bounds
        let maxEnd = min(base + recordSize, pageData.count)
        var end = absOffset
        while end < maxEnd && pageData[end] != 0 {
            end += 1
        }
        return String(data: pageData[absOffset..<end], encoding: .utf8)
    }
}
