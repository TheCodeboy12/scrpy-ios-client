import XCTest
@testable import ScrcpyKit

final class AdbMessageTests: XCTestCase {
    func testHeaderSerializationAndDeserialization() {
        let payload = "host::features=cmd,shell_v2\0".data(using: .utf8)!
        let original = AdbMessage(command: .cnxn, arg0: 0x01000000, arg1: 256 * 1024, payload: payload)

        let serialized = original.serialize()
        XCTAssertEqual(serialized.count, AdbMessage.headerSize + payload.count)

        let parsed = AdbMessage(headerData: serialized.subdata(in: 0..<AdbMessage.headerSize), payload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.command, .cnxn)
        XCTAssertEqual(parsed?.arg0, 0x01000000)
        XCTAssertEqual(parsed?.arg1, 256 * 1024)
        XCTAssertEqual(parsed?.dataLength, UInt32(payload.count))
        XCTAssertEqual(parsed?.magic, AdbCommand.cnxn.rawValue ^ 0xFFFFFFFF)
        XCTAssertEqual(parsed?.payload, payload)
    }

    func testChecksumCalculation() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let checksum = AdbMessage.checksum(for: payload)
        XCTAssertEqual(checksum, 10)
    }

    func testCommands() {
        XCTAssertEqual(AdbCommand.cnxn.name, "CNXN")
        XCTAssertEqual(AdbCommand.auth.name, "AUTH")
        XCTAssertEqual(AdbCommand.open.name, "OPEN")
        XCTAssertEqual(AdbCommand.okay.name, "OKAY")
        XCTAssertEqual(AdbCommand.clse.name, "CLSE")
        XCTAssertEqual(AdbCommand.wrte.name, "WRTE")
        XCTAssertEqual(AdbCommand.sync.name, "SYNC")
    }
}
