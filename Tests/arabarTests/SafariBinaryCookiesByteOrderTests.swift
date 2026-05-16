import XCTest
@testable import arabar

final class SafariBinaryCookiesByteOrderTests: XCTestCase {

    // readUInt32BE([0x00, 0x00, 0x01, 0x00]) → 256
    func testReadUInt32BE_256() {
        let data = Data([0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual(SafariBinaryCookies.readUInt32BE(data: data, offset: 0), 256)
    }

    // readUInt32LE([0x00, 0x01, 0x00, 0x00]) → 256
    func testReadUInt32LE_256() {
        let data = Data([0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(SafariBinaryCookies.readUInt32LE(data: data, offset: 0), 256)
    }

    // readUInt32BE([0xFF, 0xFF, 0xFF, 0xFF]) → UInt32.max
    func testReadUInt32BE_max() {
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(SafariBinaryCookies.readUInt32BE(data: data, offset: 0), UInt32.max)
    }

    // readFloat64LE with IEEE 754 LE bytes for 1.0 → 1.0
    func testReadFloat64LE_one() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F])
        XCTAssertEqual(SafariBinaryCookies.readFloat64LE(data: data, offset: 0), 1.0, accuracy: 1e-15)
    }

    // readUInt32BE with non-zero offset picks up from the correct byte
    func testReadUInt32BE_nonZeroOffset() {
        // bytes: [0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00]
        // at offset 4: [0x00, 0x01, 0x00, 0x00] BE → 65536
        let data = Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(SafariBinaryCookies.readUInt32BE(data: data, offset: 4), 65536)
    }
}
