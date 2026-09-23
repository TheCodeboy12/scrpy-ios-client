import XCTest
@testable import ScrcpyKit

final class ScrcpyProtocolTests: XCTestCase {
    func testSessionPacketParsing() {
        var data = Data()
        var flags: UInt32 = 0x80000001.bigEndian // Session flag | client resize
        var width: UInt32 = 1080.bigEndian
        var height: UInt32 = 2400.bigEndian

        Swift.withUnsafeBytes(of: &flags) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &width) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &height) { data.append(contentsOf: $0) }

        let session = ScrcpySessionMeta(data: data)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.width, 1080)
        XCTAssertEqual(session?.height, 2400)
        XCTAssertEqual(session?.isClientResize, true)
    }

    func testMediaPacketHeaderParsing() {
        var data = Data()
        // pts = 1234567, isKeyFrame = true, isConfig = false
        var ptsAndFlags: UInt64 = (0x2000000000000000 | 1234567).bigEndian
        var packetSize: UInt32 = 4096.bigEndian

        Swift.withUnsafeBytes(of: &ptsAndFlags) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &packetSize) { data.append(contentsOf: $0) }

        let header = ScrcpyMediaPacketHeader(data: data)
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.pts, 1234567)
        XCTAssertEqual(header?.isKeyFrame, true)
        XCTAssertEqual(header?.isConfig, false)
        XCTAssertEqual(header?.packetSize, 4096)
    }

    func testInjectTouchEventSerialization() {
        let msg = ScrcpyControlMessage.injectTouchEvent(
            action: .down,
            pointerId: 0,
            x: 540,
            y: 1200,
            screenWidth: 1080,
            screenHeight: 2400,
            pressure: 1.0
        )

        let data = msg.serialize()
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(data[0], 2) // TYPE_INJECT_TOUCH_EVENT
        XCTAssertEqual(data[1], 0) // ACTION_DOWN

        let posX = data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: Int32.self).bigEndian }
        let posY = data.withUnsafeBytes { $0.load(fromByteOffset: 14, as: Int32.self).bigEndian }
        let sw = data.withUnsafeBytes { $0.load(fromByteOffset: 18, as: UInt16.self).bigEndian }
        let sh = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self).bigEndian }
        let pressure = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self).bigEndian }

        XCTAssertEqual(posX, 540)
        XCTAssertEqual(posY, 1200)
        XCTAssertEqual(sw, 1080)
        XCTAssertEqual(sh, 2400)
        XCTAssertEqual(pressure, 0xFFFF)
    }

    func testInjectKeycodeSerialization() {
        let msg = ScrcpyControlMessage.injectKeycode(action: .down, keycode: .home)
        let data = msg.serialize()
        XCTAssertEqual(data.count, 14)
        XCTAssertEqual(data[0], 0) // TYPE_INJECT_KEYCODE
        XCTAssertEqual(data[1], 0) // ACTION_DOWN

        let kc = data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt32.self).bigEndian }
        XCTAssertEqual(kc, AndroidKeycode.home.rawValue)
    }

    func testInjectTextSerialization() {
        let text = "Hello from Scrcpy-iOS!"
        let msg = ScrcpyControlMessage.injectText(text)
        let data = msg.serialize()

        XCTAssertEqual(data[0], 1) // TYPE_INJECT_TEXT
        let len = data.withUnsafeBytes { $0.load(fromByteOffset: 1, as: UInt32.self).bigEndian }
        XCTAssertEqual(len, UInt32(text.utf8.count))

        let payload = String(data: data.subdata(in: 5..<(5 + Int(len))), encoding: .utf8)
        XCTAssertEqual(payload, text)
    }

    func testDeviceClipboardDeserialization() {
        var data = Data()
        data.append(0) // DEVICE_MSG_TYPE_CLIPBOARD
        let text = "Copied text from Android"
        data.appendBigEndian(UInt32(text.utf8.count))
        data.append(text.data(using: .utf8)!)

        let result = ScrcpyDeviceMessage.deserialize(from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.bytesConsumed, data.count)

        if case .clipboard(let clip) = result?.message {
            XCTAssertEqual(clip, text)
        } else {
            XCTFail("Expected .clipboard message")
        }
    }
}
