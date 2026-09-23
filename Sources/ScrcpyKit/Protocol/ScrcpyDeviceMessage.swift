import Foundation

public enum ScrcpyDeviceMessage: Sendable {
    case clipboard(String)
    case ackClipboard(UInt64)
    case uhidOutput(id: UInt16, data: Data)

    public static func deserialize(from data: Data) -> (message: ScrcpyDeviceMessage, bytesConsumed: Int)? {
        guard !data.isEmpty else { return nil }

        let type = data[0]
        switch type {
        case 0: // DEVICE_MSG_TYPE_CLIPBOARD
            guard data.count >= 5 else { return nil }
            let len = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian })
            guard data.count >= 5 + len else { return nil }
            let strData = data.subdata(in: 5..<(5 + len))
            let text = String(data: strData, encoding: .utf8) ?? ""
            return (.clipboard(text), 5 + len)

        case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD
            guard data.count >= 9 else { return nil }
            let seq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self).bigEndian }
            return (.ackClipboard(seq), 9)

        case 2: // DEVICE_MSG_TYPE_UHID_OUTPUT
            guard data.count >= 5 else { return nil }
            let id = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt16.self).bigEndian }
            let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 3, as: UInt16.self).bigEndian })
            guard data.count >= 5 + size else { return nil }
            let payload = data.subdata(in: 5..<(5 + size))
            return (.uhidOutput(id: id, data: payload), 5 + size)

        default:
            return nil
        }
    }
}
