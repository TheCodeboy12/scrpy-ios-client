import XCTest
@testable import ScrcpyKit

final class AdbCryptoTests: XCTestCase {
    func testTokenSigning() {
        let crypto = AdbCrypto()
        let fakeToken = Data(repeating: 0x42, count: 20)
        let signature = crypto.sign(token: fakeToken)
        XCTAssertNotNil(signature)
        // RSA-2048 signature must be 256 bytes
        XCTAssertEqual(signature?.count, 256)
    }

    func testAndroidPublicKeyStringFormat() {
        let crypto = AdbCrypto()
        let pubKeyPayload = crypto.getAdbPublicKeyPayload()
        guard let pubKeyStr = String(data: pubKeyPayload, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters) else {
            XCTFail("Failed to decode public key string")
            return
        }

        let parts = pubKeyStr.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertEqual(parts.last, "scrcpy@ios")

        let b64Part = String(parts[0])
        guard let binaryData = Data(base64Encoded: b64Part) else {
            XCTFail("Invalid base64 in adb key")
            return
        }

        // RSAPublicKey binary struct is exactly 524 bytes:
        // 4 (len) + 4 (n0inv) + 256 (modulus) + 256 (rr) + 4 (exponent) = 524
        XCTAssertEqual(binaryData.count, 524)

        // Check modulus size words == 64
        let words = binaryData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        XCTAssertEqual(words, 64)
    }
}
