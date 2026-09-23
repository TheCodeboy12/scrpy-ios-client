import Foundation
import Security

/// Manages RSA-2048 keys and authentication for ADB
public final class AdbCrypto: @unchecked Sendable {
    public static let shared = AdbCrypto()

    private var privateKey: SecKey?
    private var publicKeyData: Data?
    private var cachedAdbPublicKeyString: String?

    public init() {
        loadOrGenerateKey()
    }

    private func loadOrGenerateKey() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let keyDir = appSupport.appendingPathComponent("com.scrcpy.ios", isDirectory: true)
        let keyFile = keyDir.appendingPathComponent("adbkey.der")

        let importAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]

        if let derData = try? Data(contentsOf: keyFile) {
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(derData as CFData, importAttrs as CFDictionary, &error) {
                self.privateKey = key
                extractPublicKey()
                return
            }
        }

        // Generate new RSA-2048 key
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]

        var error: Unmanaged<CFError>?
        guard let newKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            return
        }
        self.privateKey = newKey
        extractPublicKey()

        // Persist DER representation to disk
        if let der = SecKeyCopyExternalRepresentation(newKey, &error) as Data? {
            try? fileManager.createDirectory(at: keyDir, withIntermediateDirectories: true)
            try? der.write(to: keyFile)
        }
    }

    private func extractPublicKey() {
        guard let priv = privateKey,
              let pub = SecKeyCopyPublicKey(priv) else { return }
        var error: Unmanaged<CFError>?
        if let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? {
            self.publicKeyData = data
            self.cachedAdbPublicKeyString = generateAndroidPublicKeyString(derData: data)
        }
    }

    /// Sign the 20-byte ADB token using RSA-2048 PKCS#1 v1.5 with SHA1 digest
    public func sign(token: Data) -> Data? {
        guard let priv = privateKey else { return nil }

        // Android adbd verifies with RSA_verify(NID_sha1, token, 20, sig, 256, rsa).
        // Since token is already the 20-byte digest, we MUST sign it as a digest (not a raw message).
        var error: Unmanaged<CFError>?
        let algorithm: SecKeyAlgorithm = .rsaSignatureDigestPKCS1v15SHA1

        guard SecKeyIsAlgorithmSupported(priv, .sign, algorithm) else {
            return nil
        }

        guard let signature = SecKeyCreateSignature(priv, algorithm, token as CFData, &error) as Data? else {
            return nil
        }
        return signature
    }

    /// Formats the RSA public key into Android ADB public key string format:
    /// `<base64_encoded_RSAPublicKey> scrcpy@ios\0`
    public func getAdbPublicKeyPayload() -> Data {
        if let cached = cachedAdbPublicKeyString, let data = (cached + "\0").data(using: .utf8) {
            return data
        }
        return "scrcpy@ios\0".data(using: .utf8)!
    }

    private func generateAndroidPublicKeyString(derData: Data) -> String? {
        // Parse PKCS#1 DER: SEQUENCE { INTEGER modulus, INTEGER exponent }
        guard derData.count > 10, derData[0] == 0x30 else { return nil }

        var offset = 1
        if derData[offset] == 0x82 {
            offset += 3
        } else if derData[offset] == 0x81 {
            offset += 2
        } else {
            offset += 1
        }

        // Modulus
        guard offset < derData.count, derData[offset] == 0x02 else { return nil }
        offset += 1
        var modLen = 0
        if derData[offset] == 0x82 {
            modLen = (Int(derData[offset + 1]) << 8) | Int(derData[offset + 2])
            offset += 3
        } else if derData[offset] == 0x81 {
            modLen = Int(derData[offset + 1])
            offset += 2
        } else {
            modLen = Int(derData[offset])
            offset += 1
        }

        var modBytes = derData.subdata(in: offset..<(offset + modLen))
        offset += modLen
        if modBytes.first == 0x00 {
            modBytes = modBytes.dropFirst()
        }
        guard modBytes.count == 256 else { return nil }

        // Exponent
        guard offset < derData.count, derData[offset] == 0x02 else { return nil }
        offset += 1
        let expLen = Int(derData[offset])
        offset += 1
        let expBytes = derData.subdata(in: offset..<(offset + expLen))
        var exp: UInt32 = 0
        for b in expBytes {
            exp = (exp << 8) | UInt32(b)
        }

        // Modulus in little-endian order
        let modLE = Data(modBytes.reversed())

        // Compute n0inv = -1 / N[0] mod 2^32
        let n0 = modLE.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        var x: UInt32 = 1
        for _ in 0..<5 {
            x = x &* (2 &- n0 &* x)
        }
        let n0inv = 0 &- x

        // Compute rr = (2^2048)^2 mod N
        let rrLE = computeRR(modulusLE: modLE)

        // Construct 524-byte RSAPublicKey binary struct
        var structData = Data(capacity: 524)
        structData.append(value: UInt32(64)) // 2048 / 32
        structData.append(value: n0inv)
        structData.append(modLE)
        structData.append(rrLE)
        structData.append(value: exp)

        let b64 = structData.base64EncodedString()
        return "\(b64) scrcpy@ios"
    }

    private func computeRR(modulusLE: Data) -> Data {
        var nWords = [UInt32](repeating: 0, count: 65)
        for i in 0..<64 {
            let offset = i * 4
            let w = UInt32(modulusLE[offset]) |
                    (UInt32(modulusLE[offset + 1]) << 8) |
                    (UInt32(modulusLE[offset + 2]) << 16) |
                    (UInt32(modulusLE[offset + 3]) << 24)
            nWords[i] = w
        }

        // Start with R mod N = 2^2048 - N
        var xWords = [UInt32](repeating: 0, count: 65)
        var borrow: Int64 = 0
        for i in 0..<64 {
            let diff = 0 - Int64(nWords[i]) - borrow
            if diff < 0 {
                xWords[i] = UInt32(diff + 0x1_0000_0000)
                borrow = 1
            } else {
                xWords[i] = UInt32(diff)
                borrow = 0
            }
        }

        // Double and reduce 2048 times to get (2^2048)^2 mod N
        for _ in 0..<2048 {
            // Shift xWords left by 1
            var carry: UInt32 = 0
            for i in 0..<65 {
                let nextCarry = xWords[i] >> 31
                xWords[i] = (xWords[i] << 1) | carry
                carry = nextCarry
            }

            // Compare xWords >= nWords
            var isGte = false
            if xWords[64] > 0 {
                isGte = true
            } else {
                isGte = true
                for i in (0..<64).reversed() {
                    if xWords[i] > nWords[i] { isGte = true; break }
                    if xWords[i] < nWords[i] { isGte = false; break }
                }
            }

            if isGte {
                var b: Int64 = 0
                for i in 0..<64 {
                    let diff = Int64(xWords[i]) - Int64(nWords[i]) - b
                    if diff < 0 {
                        xWords[i] = UInt32(diff + 0x1_0000_0000)
                        b = 1
                    } else {
                        xWords[i] = UInt32(diff)
                        b = 0
                    }
                }
                xWords[64] = 0
            }
        }

        var rrData = Data(capacity: 256)
        for i in 0..<64 {
            rrData.append(value: xWords[i])
        }
        return rrData
    }
}
