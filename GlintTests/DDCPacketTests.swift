import XCTest
@testable import Glint

/// DDC/CI framing (VESA DDC/CI 1.1): host packets are checksummed by XOR-ing the
/// destination (0x6E), the source (0x51) and every payload byte.
final class DDCPacketTests: XCTestCase {
    private func xor(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0, ^) }

    // MARK: Known vectors

    func testGetVCPBrightnessMatchesTheCanonicalDDCVector() {
        // The well-known DDC/CI "get brightness" request on the wire is 6E 51 82 01 10 AC.
        XCTAssertEqual(DDCPacket.avGetVCP(command: VCPCode.brightness.rawValue), [0x82, 0x01, 0x10, 0xAC])
        XCTAssertEqual(DDCPacket.i2cGetVCP(command: VCPCode.brightness.rawValue), [0x51, 0x82, 0x01, 0x10, 0xAC])
    }

    func testSetBrightnessTo50() {
        XCTAssertEqual(
            DDCPacket.avSetVCP(command: VCPCode.brightness.rawValue, value: 50),
            [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
        )
    }

    func testSetVolumeToZero() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x62 ^ 0x00 ^ 0x00 = 0xDA
        XCTAssertEqual(
            DDCPacket.avSetVCP(command: VCPCode.volume.rawValue, value: 0),
            [0x84, 0x03, 0x62, 0x00, 0x00, 0xDA]
        )
    }

    func testValueIsSplitBigEndian() {
        let packet = DDCPacket.avSetVCP(command: VCPCode.brightness.rawValue, value: 0x1234)
        XCTAssertEqual(packet[3], 0x12)
        XCTAssertEqual(packet[4], 0x34)

        let maxPacket = DDCPacket.avSetVCP(command: VCPCode.contrast.rawValue, value: 0xFFFF)
        XCTAssertEqual(Array(maxPacket[3...4]), [0xFF, 0xFF])
    }

    // MARK: Checksum property

    func testEveryPacketChecksumsToXorOfAddressesAndPayload() {
        let codes: [VCPCode] = [.brightness, .contrast, .volume, .audioMute, .powerMode]
        let values: [UInt16] = [0, 1, 50, 100, 0x00FF, 0x0100, 0x1234, 0xFFFF]
        for code in codes {
            let get = DDCPacket.avGetVCP(command: code.rawValue)
            XCTAssertEqual(get.count, 4)
            XCTAssertEqual(get.last, xor([0x6E, 0x51] + get.dropLast()), "GET \(code)")

            let i2cGet = DDCPacket.i2cGetVCP(command: code.rawValue)
            // The I2C form carries 0x51 in the buffer, so seeding with 0x6E covers it.
            XCTAssertEqual(i2cGet.last, xor([0x6E] + i2cGet.dropLast()), "I2C GET \(code)")
            XCTAssertEqual(Array(i2cGet.dropFirst()), get, "I2C GET is the AV packet prefixed with 0x51")

            for value in values {
                let set = DDCPacket.avSetVCP(command: code.rawValue, value: value)
                XCTAssertEqual(set.count, 6)
                XCTAssertEqual(Array(set[0...2]), [0x84, 0x03, code.rawValue])
                XCTAssertEqual(set.last, xor([0x6E, 0x51] + set.dropLast()), "SET \(code)=\(value)")

                let i2cSet = DDCPacket.i2cSetVCP(command: code.rawValue, value: value)
                XCTAssertEqual(Array(i2cSet.dropFirst()), set, "I2C SET \(code)=\(value)")
                // A receiver validates by XOR-ing the whole frame incl. destination: must be 0.
                XCTAssertEqual(xor([0x6E] + i2cSet), 0)
            }
        }
    }

    // MARK: AV reply parsing

    /// A real-shaped reply: source 0x6E, length 0x88, opcode 0x02, result 0x00, VCP echo,
    /// type, max hi/lo, current hi/lo, checksum (+ one byte of padding in the 12-byte buffer).
    private func reply(vcp: UInt8, max: UInt16, current: UInt16) -> [UInt8] {
        [0x6E, 0x88, 0x02, 0x00, vcp, 0x00,
         UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF),
         0x00, 0x00]
    }

    func testParsesBrightnessReply() {
        let result = DDCPacket.parseAVReply(reply(vcp: 0x10, max: 100, current: 50), command: 0x10)
        XCTAssertEqual(result?.maxValue, 100)
        XCTAssertEqual(result?.currentValue, 50)
    }

    func testDecodesBigEndianSixteenBitValues() {
        let result = DDCPacket.parseAVReply(reply(vcp: 0x62, max: 0x0102, current: 0x00FF), command: 0x62)
        XCTAssertEqual(result?.maxValue, 0x0102)
        XCTAssertEqual(result?.currentValue, 0x00FF)
    }

    func testFindsReplyAfterLeadingGarbage() {
        let shifted: [UInt8] = [0x00, 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x00]
        let result = DDCPacket.parseAVReply(shifted, command: 0x10)
        XCTAssertEqual(result?.maxValue, 100)
        XCTAssertEqual(result?.currentValue, 75)
    }

    func testRejectsReplyForADifferentVCP() {
        // A brightness reply must not be accepted as a volume value (wrong port / stale reply).
        XCTAssertNil(DDCPacket.parseAVReply(reply(vcp: 0x10, max: 100, current: 50), command: 0x62))
    }

    func testRejectsAllZeroBuffer() {
        // What an empty port (Mac mini HDMI with nothing attached) hands back.
        XCTAssertNil(DDCPacket.parseAVReply([UInt8](repeating: 0, count: 12), command: 0x10))
    }

    func testRejectsTruncatedReply() {
        let full = reply(vcp: 0x10, max: 100, current: 50)
        // opcode at index 2 needs bytes up to index 9 (current lo).
        XCTAssertNil(DDCPacket.parseAVReply(Array(full.prefix(9)), command: 0x10))
        XCTAssertNotNil(DDCPacket.parseAVReply(Array(full.prefix(10)), command: 0x10))
        XCTAssertEqual(DDCPacket.parseAVReply(Array(full.prefix(10)), command: 0x10)?.currentValue, 50)
    }

    func testRejectsEmptyReply() {
        XCTAssertNil(DDCPacket.parseAVReply([], command: 0x10))
    }

    // MARK: I2C reply parsing

    func testParsesI2CReply() {
        let result = DDCPacket.parseI2CReply(reply(vcp: 0x10, max: 100, current: 30), command: 0x10)
        XCTAssertEqual(result?.maxValue, 100)
        XCTAssertEqual(result?.currentValue, 30)
    }

    func testI2CRejectsWrongOpcodeWrongVCPAndShortBuffers() {
        var badOpcode = reply(vcp: 0x10, max: 100, current: 30)
        badOpcode[2] = 0x03
        XCTAssertNil(DDCPacket.parseI2CReply(badOpcode, command: 0x10))
        XCTAssertNil(DDCPacket.parseI2CReply(reply(vcp: 0x10, max: 100, current: 30), command: 0x62))
        XCTAssertNil(DDCPacket.parseI2CReply(Array(reply(vcp: 0x10, max: 100, current: 30).prefix(10)), command: 0x10))
    }
}
