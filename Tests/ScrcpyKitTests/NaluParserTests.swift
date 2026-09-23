import XCTest
@testable import ScrcpyKit

final class NaluParserTests: XCTestCase {
    func testAnnexBParsing() {
        var rawStream = Data()

        // NALU 1: H.264 SPS (type 7) with 4-byte start code
        rawStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        rawStream.append(contentsOf: [0x67, 0x42, 0x00, 0x1f, 0x96, 0x35])

        // NALU 2: H.264 PPS (type 8) with 3-byte start code
        rawStream.append(contentsOf: [0x00, 0x00, 0x01])
        rawStream.append(contentsOf: [0x68, 0xce, 0x3c, 0x80])

        // NALU 3: IDR slice (type 5) with 4-byte start code
        rawStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        rawStream.append(contentsOf: [0x65, 0x88, 0x84, 0x00, 0x33])

        let units = NaluParser.parseAnnexB(data: rawStream)
        XCTAssertEqual(units.count, 3)

        XCTAssertTrue(units[0].isH264SPS)
        XCTAssertEqual(units[0].data.count, 6)

        XCTAssertTrue(units[1].isH264PPS)
        XCTAssertEqual(units[1].data.count, 4)

        XCTAssertTrue(units[2].isH264IDR)
        XCTAssertEqual(units[2].data.count, 5)
    }

    func testAvccConversion() {
        let nalu1 = NaluUnit(type: 0x65, data: Data([0x65, 0x01, 0x02]))
        let nalu2 = NaluUnit(type: 0x41, data: Data([0x41, 0x03, 0x04, 0x05]))

        let avcc = NaluParser.convertToAvcc(nalUnits: [nalu1, nalu2])

        // Length 1: 3 (4 bytes BE) + 3 bytes = 7 bytes
        // Length 2: 4 (4 bytes BE) + 4 bytes = 8 bytes
        // Total = 15 bytes
        XCTAssertEqual(avcc.count, 15)

        let len1 = avcc.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        XCTAssertEqual(len1, 3)

        let len2 = avcc.withUnsafeBytes { $0.load(fromByteOffset: 7, as: UInt32.self).bigEndian }
        XCTAssertEqual(len2, 4)
    }
}
