import XCTest
@testable import DisplayProtocol

final class PacketTests: XCTestCase {
    func testKnownWireRequests() {
        XCTAssertEqual(Packet.read(), [0x82, 0x01, 0x10, 0xac])
        XCTAssertEqual(Packet.write(50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9a])
        XCTAssertEqual(Packet.write(0x1234), [0x84, 0x03, 0x10, 0x12, 0x34, 0x8e])
    }
    func reply(current: Int = 50, max: Int = 100, feature: UInt8 = 0x10, result: UInt8 = 0) -> [UInt8] {
        let bytes: [UInt8] = [0x6e, 0x88, 2, result, feature, 0, UInt8(max >> 8), UInt8(max & 255), UInt8(current >> 8), UInt8(current & 255)]
        return bytes + [bytes.reduce(UInt8(0x50), ^)]
    }
    func testReadsFull16BitValuesAndScales() throws {
        let value = try Packet.parse(reply(current: 500, max: 1000))
        XCTAssertEqual(value.current, 500); XCTAssertEqual(value.maximum, 1000); XCTAssertEqual(value.percent, 50)
    }
    func testVolumeUsesItsOwnFeatureAndValidatesReply() throws {
        XCTAssertEqual(Packet.read(.volume), [0x82, 0x01, 0x62, 0xde])
        XCTAssertEqual(Packet.write(50, feature: .volume), [0x84, 0x03, 0x62, 0, 0x32, 0xe8])
        XCTAssertEqual(try Packet.parse(reply(feature: 0x62), feature: .volume).percent, 50)
        XCTAssertThrowsError(try Packet.parse(reply(), feature: .volume))
    }
    func testRejectsBadChecksumWrongFeatureAndUnsupported() {
        var bad = reply(); bad[10] ^= 1
        for bytes in [bad, Array(reply().prefix(10)), reply(feature: 0x12), reply(result: 1), reply(current: 0, max: 0), reply(current: 101)] {
            XCTAssertThrowsError(try Packet.parse(bytes))
        }
    }
}
