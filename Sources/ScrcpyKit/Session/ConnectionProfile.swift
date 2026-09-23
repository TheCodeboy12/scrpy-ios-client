import Foundation

/// Connection Profile representing a remembered Android device and its customized streaming settings
public struct ConnectionProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var videoSource: ScrcpyVideoSource
    public var cameraFacing: ScrcpyCameraFacing
    public var resolution: Int
    public var bitrateMbps: Double
    public var fps: Int
    public var codec: ScrcpyVideoCodec
    public var audioEnabled: Bool
    public var stayAwake: Bool
    public var showTouches: Bool
    public var customServerArgs: String
    public var lastConnected: Date?

    public init(
        id: UUID = UUID(),
        name: String = "Android Device",
        host: String = "10.0.0.30",
        port: UInt16 = 5555,
        videoSource: ScrcpyVideoSource = .display,
        cameraFacing: ScrcpyCameraFacing = .back,
        resolution: Int = 1920,
        bitrateMbps: Double = 8.0,
        fps: Int = 60,
        codec: ScrcpyVideoCodec = .h264,
        audioEnabled: Bool = true,
        stayAwake: Bool = true,
        showTouches: Bool = false,
        customServerArgs: String = "",
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.videoSource = videoSource
        self.cameraFacing = cameraFacing
        self.resolution = resolution
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.codec = codec
        self.audioEnabled = audioEnabled
        self.stayAwake = stayAwake
        self.showTouches = showTouches
        self.customServerArgs = customServerArgs
        self.lastConnected = lastConnected
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, videoSource, cameraFacing, resolution, bitrateMbps, fps, codec
        case audioEnabled, stayAwake, showTouches, customServerArgs, lastConnected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Android Device"
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "10.0.0.30"
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 5555
        self.videoSource = try container.decodeIfPresent(ScrcpyVideoSource.self, forKey: .videoSource) ?? .display
        self.cameraFacing = try container.decodeIfPresent(ScrcpyCameraFacing.self, forKey: .cameraFacing) ?? .back
        self.resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 1920
        self.bitrateMbps = try container.decodeIfPresent(Double.self, forKey: .bitrateMbps) ?? 8.0
        self.fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        self.codec = try container.decodeIfPresent(ScrcpyVideoCodec.self, forKey: .codec) ?? .h264
        self.audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        self.stayAwake = try container.decodeIfPresent(Bool.self, forKey: .stayAwake) ?? true
        self.showTouches = try container.decodeIfPresent(Bool.self, forKey: .showTouches) ?? false
        self.customServerArgs = try container.decodeIfPresent(String.self, forKey: .customServerArgs) ?? ""
        self.lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
    }
}
