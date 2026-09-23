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
}
