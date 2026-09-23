import Foundation

/// ADB Protocol Command Constants
public enum AdbCommand: UInt32, Sendable {
    case sync = 0x434e5953 // "SYNC"
    case cnxn = 0x4e584e43 // "CNXN"
    case auth = 0x48545541 // "AUTH"
    case open = 0x4e45504f // "OPEN"
    case okay = 0x59414b4f // "OKAY"
    case clse = 0x45534c43 // "CLSE"
    case wrte = 0x45545257 // "WRTE"

    public var name: String {
        switch self {
        case .sync: return "SYNC"
        case .cnxn: return "CNXN"
        case .auth: return "AUTH"
        case .open: return "OPEN"
        case .okay: return "OKAY"
        case .clse: return "CLSE"
        case .wrte: return "WRTE"
        }
    }
}

/// ADB Protocol Message Header (24 bytes)
public struct AdbMessage: Sendable {
    public static let headerSize = 24
    public static let maxPayloadSize: UInt32 = 256 * 1024 // 256 KB

    public let command: AdbCommand
    public let arg0: UInt32
    public let arg1: UInt32
    public let dataLength: UInt32
    public let dataCheck: UInt32
    public let magic: UInt32
    public let payload: Data

    public init(command: AdbCommand, arg0: UInt32, arg1: UInt32, payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.dataLength = UInt32(payload.count)
        self.dataCheck = AdbMessage.checksum(for: payload)
        self.magic = command.rawValue ^ 0xFFFFFFFF
        self.payload = payload
    }

    public init?(headerData: Data, payload: Data = Data()) {
        guard headerData.count >= AdbMessage.headerSize else { return nil }

        let cmdRaw = headerData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard let command = AdbCommand(rawValue: cmdRaw) else { return nil }

        let arg0 = headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let arg1 = headerData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let dataLength = headerData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let dataCheck = headerData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let magic = headerData.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        guard magic == (cmdRaw ^ 0xFFFFFFFF) else { return nil }

        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.dataLength = dataLength
        self.dataCheck = dataCheck
        self.magic = magic
        self.payload = payload
    }

    public func serialize() -> Data {
        var data = Data(capacity: AdbMessage.headerSize + payload.count)
        data.append(value: command.rawValue)
        data.append(value: arg0)
        data.append(value: arg1)
        data.append(value: dataLength)
        data.append(value: dataCheck)
        data.append(value: magic)
        if !payload.isEmpty {
            data.append(payload)
        }
        return data
    }

    public static func checksum(for data: Data) -> UInt32 {
        var sum: UInt32 = 0
        for byte in data {
            sum &+= UInt32(byte)
        }
        return sum
    }
}
