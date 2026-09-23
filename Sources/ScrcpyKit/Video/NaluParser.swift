import Foundation
import CoreMedia

public struct NaluUnit: Sendable {
    public let type: UInt8
    public let data: Data // Data excluding start code

    public var isH264SPS: Bool { (type & 0x1F) == 7 }
    public var isH264PPS: Bool { (type & 0x1F) == 8 }
    public var isH264IDR: Bool { (type & 0x1F) == 5 }

    public var isH265VPS: Bool { ((type >> 1) & 0x3F) == 32 }
    public var isH265SPS: Bool { ((type >> 1) & 0x3F) == 33 }
    public var isH265PPS: Bool { ((type >> 1) & 0x3F) == 34 }
    public var isH265IDR: Bool {
        let t = (type >> 1) & 0x3F
        return t >= 16 && t <= 21
    }
}

/// Parses Annex B NAL units and converts them to AVCC/HVCC length-prefixed blocks
public final class NaluParser: Sendable {
    public init() {}

    /// Extracts all NAL units separated by 00 00 01 or 00 00 00 01 start codes
    public static func parseAnnexB(data: Data) -> [NaluUnit] {
        var units = [NaluUnit]()
        guard data.count > 4 else { return units }

        var indices = [Int]()
        let count = data.count
        var i = 0

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            while i < count - 2 {
                if ptr[i] == 0 && ptr[i + 1] == 0 {
                    if ptr[i + 2] == 1 {
                        // 3-byte start code: 00 00 01
                        indices.append(i)
                        i += 3
                        continue
                    } else if i < count - 3 && ptr[i + 2] == 0 && ptr[i + 3] == 1 {
                        // 4-byte start code: 00 00 00 01
                        indices.append(i)
                        i += 4
                        continue
                    }
                }
                i += 1
            }
        }

        guard !indices.isEmpty else { return units }

        for idx in 0..<indices.count {
            let start = indices[idx]
            let nextStart = (idx + 1 < indices.count) ? indices[idx + 1] : data.count

            // Determine start code length (3 or 4 bytes)
            let scLen: Int
            if data[start + 2] == 1 {
                scLen = 3
            } else {
                scLen = 4
            }

            let naluStart = start + scLen
            guard naluStart < nextStart else { continue }

            let naluData = data.subdata(in: naluStart..<nextStart)
            guard let firstByte = naluData.first else { continue }
            units.append(NaluUnit(type: firstByte, data: naluData))
        }

        return units
    }

    /// Converts Annex-B NAL units to AVCC length-prefixed format (4 bytes BE length + payload)
    public static func convertToAvcc(nalUnits: [NaluUnit]) -> Data {
        var avccData = Data()
        for unit in nalUnits {
            avccData.appendBigEndian(UInt32(unit.data.count))
            avccData.append(unit.data)
        }
        return avccData
    }
}
