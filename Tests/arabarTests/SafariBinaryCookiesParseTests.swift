import XCTest
@testable import arabar

final class SafariBinaryCookiesParseTests: XCTestCase {

    // Helper: write UInt32 big-endian into Data
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    // Helper: write UInt32 little-endian into Data
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }

    // Helper: write Float64 little-endian into Data
    private func leDouble(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern.littleEndian
        return (0..<8).map { UInt8(bits >> ($0 * 8) & 0xFF) }
    }

    // Truncated data (< 8 bytes) → throws .invalidFormat("File too small")
    func testTruncatedData_throwsFileTooSmall() {
        let data = Data([0x63, 0x6F, 0x6F])  // only 3 bytes
        XCTAssertThrowsError(try SafariBinaryCookies.parse(data: data, matching: [])) { error in
            guard case SafariCookiesError.invalidFormat(let msg) = error else {
                XCTFail("Expected invalidFormat, got \(error)")
                return
            }
            XCTAssertEqual(msg, "File too small")
        }
    }

    // Bad magic bytes → throws .invalidFormat("Bad magic bytes")
    func testBadMagicBytes_throwsBadMagicBytes() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try SafariBinaryCookies.parse(data: data, matching: [])) { error in
            guard case SafariCookiesError.invalidFormat(let msg) = error else {
                XCTFail("Expected invalidFormat, got \(error)")
                return
            }
            XCTAssertEqual(msg, "Bad magic bytes")
        }
    }

    // Minimal valid fixture: one page + one cookie with domain "claude.ai"
    func testMinimalValidFixture_returnsCookie() throws {
        // We build a complete valid binary cookies blob for one cookie
        // Cookie record layout (all LE unless noted):
        //   +0:  recordSize (UInt32 LE)
        //   +4:  unknown (4 bytes, 0)
        //   +8:  flags (UInt32 LE) — 0x01 = secure
        //   +12: unknown (4 bytes, 0)
        //   +16: domainOffset (UInt32 LE) — relative to record start
        //   +20: nameOffset (UInt32 LE)
        //   +24: pathOffset (UInt32 LE)
        //   +28: valueOffset (UInt32 LE)
        //   +32: unknown (4 bytes, 0)
        //   +36: unknown (4 bytes, 0)
        //   +40: expiry (Float64 LE, Apple epoch) — use 1.0 → expiry in 2001+1s
        //   +48: creation (Float64 LE)
        //   +56: string data (domain\0name\0path\0value\0)

        let domain = "claude.ai"
        let name   = "sessionKey"
        let path   = "/"
        let value  = "abc123"

        var strings = Data()
        let domainOff = 56
        strings.append(contentsOf: domain.utf8); strings.append(0)
        let nameOff = domainOff + domain.utf8.count + 1
        strings.append(contentsOf: name.utf8); strings.append(0)
        let pathOff = nameOff + name.utf8.count + 1
        strings.append(contentsOf: path.utf8); strings.append(0)
        let valueOff = pathOff + path.utf8.count + 1
        strings.append(contentsOf: value.utf8); strings.append(0)

        let recordSize = 56 + strings.count

        var cookieRecord = Data()
        cookieRecord.append(contentsOf: le32(UInt32(recordSize)))  // +0 recordSize
        cookieRecord.append(contentsOf: [0,0,0,0])                 // +4 unknown
        cookieRecord.append(contentsOf: le32(0x01))                // +8 flags (secure)
        cookieRecord.append(contentsOf: [0,0,0,0])                 // +12 unknown
        cookieRecord.append(contentsOf: le32(UInt32(domainOff)))   // +16 domainOffset
        cookieRecord.append(contentsOf: le32(UInt32(nameOff)))     // +20 nameOffset
        cookieRecord.append(contentsOf: le32(UInt32(pathOff)))     // +24 pathOffset
        cookieRecord.append(contentsOf: le32(UInt32(valueOff)))    // +28 valueOffset
        cookieRecord.append(contentsOf: [0,0,0,0])                 // +32 unknown
        cookieRecord.append(contentsOf: [0,0,0,0])                 // +36 unknown
        cookieRecord.append(contentsOf: leDouble(1.0))             // +40 expiry (Apple epoch + 1s)
        cookieRecord.append(contentsOf: leDouble(0.0))             // +48 creation
        cookieRecord.append(strings)

        // Page layout:
        //   +0:  page header tag 0x00000100 (UInt32 BE)
        //   +4:  cookieCount (UInt32 LE)
        //   +8:  cookieOffsets[0] (UInt32 LE) — offset relative to page start
        //   +12: cookie record starts here
        let cookieOffsetInPage: UInt32 = 12
        var pageData = Data()
        pageData.append(contentsOf: be32(0x00000100))              // page header tag (BE)
        pageData.append(contentsOf: le32(1))                       // cookieCount
        pageData.append(contentsOf: le32(cookieOffsetInPage))      // cookieOffsets[0]
        pageData.append(cookieRecord)

        // File layout:
        //   +0: magic "cook"
        //   +4: pageCount (UInt32 BE)
        //   +8: pageSizes[0] (UInt32 BE)
        //   +12: page data
        var file = Data()
        file.append(contentsOf: "cook".utf8)
        file.append(contentsOf: be32(1))
        file.append(contentsOf: be32(UInt32(pageData.count)))
        file.append(pageData)

        let cookies = try SafariBinaryCookies.parse(data: file, matching: ["claude.ai"])
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies.first?.name, name)
        XCTAssertEqual(cookies.first?.value, value)
        XCTAssertEqual(cookies.first?.domain, domain)
    }

    // Expiry float 0.0 → expiryDate == nil
    func testAppleEpoch_zero_expiryDateNil() throws {
        // Reuse the fixture builder pattern but set expiry = 0.0
        // Parse should return cookie with expiry == nil when expiry float <= 0
        let domain = "example.com"
        let name   = "k"
        let path   = "/"
        let value  = "v"

        var strings = Data()
        let domainOff = 56
        strings.append(contentsOf: domain.utf8); strings.append(0)
        let nameOff = domainOff + domain.utf8.count + 1
        strings.append(contentsOf: name.utf8); strings.append(0)
        let pathOff = nameOff + name.utf8.count + 1
        strings.append(contentsOf: path.utf8); strings.append(0)
        let valueOff = pathOff + path.utf8.count + 1
        strings.append(contentsOf: value.utf8); strings.append(0)
        let recordSize = 56 + strings.count

        var cookieRecord = Data()
        cookieRecord.append(contentsOf: le32(UInt32(recordSize)))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: le32(0x00))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: le32(UInt32(domainOff)))
        cookieRecord.append(contentsOf: le32(UInt32(nameOff)))
        cookieRecord.append(contentsOf: le32(UInt32(pathOff)))
        cookieRecord.append(contentsOf: le32(UInt32(valueOff)))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: leDouble(0.0))  // expiry = 0 → nil
        cookieRecord.append(contentsOf: leDouble(0.0))
        cookieRecord.append(strings)

        var pageData = Data()
        pageData.append(contentsOf: be32(0x00000100))
        pageData.append(contentsOf: le32(1))
        pageData.append(contentsOf: le32(12))
        pageData.append(cookieRecord)

        var file = Data()
        file.append(contentsOf: "cook".utf8)
        file.append(contentsOf: be32(1))
        file.append(contentsOf: be32(UInt32(pageData.count)))
        file.append(pageData)

        let cookies = try SafariBinaryCookies.parse(data: file, matching: ["example.com"])
        XCTAssertEqual(cookies.count, 1)
        XCTAssertNil(cookies.first?.expiry)
    }

    // Apple epoch: float 1.0 → Date(timeIntervalSince1970: 978307200 + 1) = 978307201
    func testAppleEpoch_one_convertsToUnixDate() throws {
        let domain = "example.org"
        let name   = "k"
        let path   = "/"
        let value  = "v"

        var strings = Data()
        let domainOff = 56
        strings.append(contentsOf: domain.utf8); strings.append(0)
        let nameOff = domainOff + domain.utf8.count + 1
        strings.append(contentsOf: name.utf8); strings.append(0)
        let pathOff = nameOff + name.utf8.count + 1
        strings.append(contentsOf: path.utf8); strings.append(0)
        let valueOff = pathOff + path.utf8.count + 1
        strings.append(contentsOf: value.utf8); strings.append(0)
        let recordSize = 56 + strings.count

        var cookieRecord = Data()
        cookieRecord.append(contentsOf: le32(UInt32(recordSize)))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: le32(0x00))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: le32(UInt32(domainOff)))
        cookieRecord.append(contentsOf: le32(UInt32(nameOff)))
        cookieRecord.append(contentsOf: le32(UInt32(pathOff)))
        cookieRecord.append(contentsOf: le32(UInt32(valueOff)))
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: [0,0,0,0])
        cookieRecord.append(contentsOf: leDouble(1.0))  // expiry = 1s after Apple epoch
        cookieRecord.append(contentsOf: leDouble(0.0))
        cookieRecord.append(strings)

        var pageData = Data()
        pageData.append(contentsOf: be32(0x00000100))
        pageData.append(contentsOf: le32(1))
        pageData.append(contentsOf: le32(12))
        pageData.append(cookieRecord)

        var file = Data()
        file.append(contentsOf: "cook".utf8)
        file.append(contentsOf: be32(1))
        file.append(contentsOf: be32(UInt32(pageData.count)))
        file.append(pageData)

        let cookies = try SafariBinaryCookies.parse(data: file, matching: ["example.org"])
        XCTAssertEqual(cookies.count, 1)
        let expected = Date(timeIntervalSince1970: 978307201)
        XCTAssertEqual(cookies.first?.expiry, expected)
    }
}
