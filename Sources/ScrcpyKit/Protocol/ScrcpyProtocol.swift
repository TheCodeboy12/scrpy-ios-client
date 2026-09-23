import Foundation

public enum ScrcpyVideoCodec: UInt32, Sendable {
    case h264 = 0x68323634 // "h264"
    case h265 = 0x68323635 // "h265"
    case av1  = 0x00617631 // "av1"
    case vp8  = 0x00767038 // "vp8"
    case vp9  = 0x00767039 // "vp9"

    public var name: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 (HEVC)"
        case .av1:  return "AV1"
        case .vp8:  return "VP8"
        case .vp9:  return "VP9"
        }
    }
}

public enum ScrcpyAudioCodec: UInt32, Sendable {
    case opus = 0x6F707573 // "opus"
    case aac  = 0x00616163 // "aac"
    case flac = 0x666C6163 // "flac"
    case raw  = 0x00726177 // "raw"
}

/// Represents the video stream session metadata sent on start or display rotation
public struct ScrcpySessionMeta: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let isClientResize: Bool

    public static let packetSize = 12

    public init?(data: Data) {
        guard data.count >= ScrcpySessionMeta.packetSize else { return nil }

        let flags = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        // Bit 31 must be set (0x80000000) for session packet
        guard (flags & 0x80000000) != 0 else { return nil }

        let isClientResize = (flags & 1) != 0
        let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian })
        let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).bigEndian })

        self.width = w
        self.height = h
        self.isClientResize = isClientResize
    }
}

/// Represents a media packet header preceding the raw video or audio frame
public struct ScrcpyMediaPacketHeader: Sendable {
    public static let headerSize = 12

    public let pts: UInt64
    public let isConfig: Bool
    public let isKeyFrame: Bool
    public let packetSize: Int

    public init?(data: Data) {
        guard data.count >= ScrcpyMediaPacketHeader.headerSize else { return nil }

        let ptsAndFlags = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self).bigEndian }
        // Bit 63 must be 0 for media packet (1 indicates session packet)
        guard (ptsAndFlags & 0x8000000000000000) == 0 else { return nil }

        let isConfig = (ptsAndFlags & 0x4000000000000000) != 0
        let isKeyFrame = (ptsAndFlags & 0x2000000000000000) != 0
        let pts = ptsAndFlags & 0x1FFFFFFFFFFFFFFF

        let size = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).bigEndian })

        self.pts = pts
        self.isConfig = isConfig
        self.isKeyFrame = isKeyFrame
        self.packetSize = size
    }
}
