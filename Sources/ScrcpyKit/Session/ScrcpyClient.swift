import Foundation
import SwiftUI
import CoreMedia

public enum ScrcpyClientState: Equatable, Sendable {
    case disconnected
    case connecting(step: String)
    case mirroring
    case error(String)
}

public enum ScrcpyVideoSource: String, Sendable, CaseIterable, Codable {
    case display = "display"
    case camera = "camera"

    public var displayName: String {
        switch self {
        case .display: return "Screen Display"
        case .camera: return "Device Camera"
        }
    }
}

public enum ScrcpyCameraFacing: String, Sendable, CaseIterable, Codable {
    case back = "back"
    case front = "front"
    case external = "external"

    public var displayName: String {
        switch self {
        case .back: return "Back Camera"
        case .front: return "Front Camera"
        case .external: return "External Camera"
        }
    }
}

@MainActor
public final class ScrcpyClient: ObservableObject {
    @Published public private(set) var state: ScrcpyClientState = .disconnected
    @Published public private(set) var deviceName: String = ""
    @Published public private(set) var videoDimensions: CGSize?
    @Published public private(set) var currentFps: Double = 0.0
    @Published public private(set) var clipboardText: String = ""
    @Published public var isTorchOn: Bool = false

    // General connection configuration
    public var host: String
    public var port: UInt16
    public var videoCodec: ScrcpyVideoCodec
    public var maxSize: Int
    public var bitRate: Int
    public var maxFps: Int
    public var audioEnabled: Bool
    public var serverVersion: String
    public var serverJarData: Data?

    // Camera & Advanced flags
    public var videoSource: ScrcpyVideoSource = .display
    public var cameraFacing: ScrcpyCameraFacing = .back
    public var cameraId: String?
    public var cameraSize: String? // e.g. "1920x1080"
    public var cameraFps: Int?
    public var cameraHighSpeed: Bool = false
    public var stayAwake: Bool = true
    public var showTouches: Bool = false
    public var customServerArgs: String = ""

    public let decoder: VideoToolboxDecoder
    public let audioPlayer = PcmAudioPlayer()
    public let recorder = StreamRecorder()
    private var adbConnection: AdbConnection?
    private var serverProcessStream: AdbStream?
    private var videoStream: AdbStream?
    private var audioStream: AdbStream?
    private var controlStream: AdbStream?

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var statsTimer: Timer?

    public init(
        host: String = "192.168.1.100",
        port: UInt16 = 5555,
        videoCodec: ScrcpyVideoCodec = .h264,
        maxSize: Int = 1920,
        bitRate: Int = 8_000_000,
        maxFps: Int = 60,
        audioEnabled: Bool = false,
        videoSource: ScrcpyVideoSource = .display,
        cameraFacing: ScrcpyCameraFacing = .back,
        serverVersion: String = "4.1",
        serverJarData: Data? = nil
    ) {
        self.host = host
        self.port = port
        self.videoCodec = videoCodec
        self.maxSize = maxSize
        self.bitRate = bitRate
        self.maxFps = maxFps
        self.audioEnabled = audioEnabled
        self.videoSource = videoSource
        self.cameraFacing = cameraFacing
        self.serverVersion = serverVersion
        self.serverJarData = serverJarData
        self.decoder = VideoToolboxDecoder(codec: videoCodec)

        setupDecoderCallbacks()
    }

    private func setupDecoderCallbacks() {
        decoder.onDimensionsChanged = { [weak self] width, height in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.videoDimensions = CGSize(width: width, height: height)
            }
        }
        decoder.addSampleBufferListener { [weak self] buffer in
            guard let self = self else { return }
            self.recorder.appendVideoSample(buffer)
        }
    }

    /// Builds the full command line arguments for scrcpy-server based on all configured flags
    public func buildServerCommandLine(scidHex: String) -> String {
        let codecParam = (videoCodec == .h265) ? "h265" : "h264"
        var args = [
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server \(serverVersion)",
            "scid=\(scidHex)",
            "log_level=info",
            "tunnel_forward=true",
            "send_device_meta=true",
            "send_frame_meta=true",
            "video_codec=\(codecParam)",
            "video_bit_rate=\(bitRate)",
            "max_fps=\(maxFps)",
            "control=true",
            "cleanup=true"
        ]

        if maxSize > 0 {
            args.append("max_size=\(maxSize)")
        }

        // Video source flags
        if videoSource == .camera {
            args.append("video_source=camera")
            args.append("camera_facing=\(cameraFacing.rawValue)")
            if let cid = cameraId, !cid.isEmpty {
                args.append("camera_id=\(cid)")
            }
            if let csize = cameraSize, !csize.isEmpty {
                args.append("camera_size=\(csize)")
            }
            if let cfps = cameraFps, cfps > 0 {
                args.append("camera_fps=\(cfps)")
            }
            if cameraHighSpeed {
                args.append("camera_high_speed=true")
            }
            // In camera mode, audio captures device microphone
            if audioEnabled {
                args.append("audio=true")
                args.append("audio_codec=raw")
                args.append("audio_source=mic")
            } else {
                args.append("audio=false")
            }
        } else {
            args.append("video_source=display")
            if audioEnabled {
                args.append("audio=true")
                args.append("audio_codec=raw")
            } else {
                args.append("audio=false")
            }
        }

        if stayAwake {
            args.append("stay_awake=true")
        }
        if showTouches {
            args.append("show_touches=true")
        }

        // Custom arguments (e.g. crop=1080:1080:0:0 angle=90)
        let trimmedCustom = customServerArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            args.append(trimmedCustom)
        }

        return args.joined(separator: " ")
    }

    /// Connects to Android device via ADB, pushes & launches scrcpy-server, and starts streaming
    public func start() {
        guard state == .disconnected || (ifCaseError) else { return }

        Task {
            do {
                self.state = .connecting(step: "Connecting to ADB (\(host):\(port))...")
                let conn = AdbConnection(host: host, port: port)
                conn.onHandshakeStep = { [weak self] step in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.state = .connecting(step: step)
                    }
                }
                self.adbConnection = conn
                try await conn.connect()

                let scid = UInt32.random(in: 0x10000000...0x7FFFFFFF)
                let scidHex = String(format: "%08x", scid)

                // Push scrcpy-server.jar
                guard let jarData = serverJarData ?? loadBundledServerJar() else {
                    throw AdbError.connectionFailed("Could not locate bundled scrcpy-server.jar in application bundle resources.")
                }
                self.state = .connecting(step: "Uploading scrcpy-server...")
                let sync = AdbSyncService(connection: conn)
                try await sync.pushFile(data: jarData, remotePath: "/data/local/tmp/scrcpy-server.jar")

                // Launch scrcpy-server via ADB shell with all flags
                self.state = .connecting(step: "Starting scrcpy server (\(videoSource.displayName))...")
                let cmd = buildServerCommandLine(scidHex: scidHex)

                let procStream = try await conn.openStream(destination: "shell:\(cmd)")
                self.serverProcessStream = procStream

                // Connect video stream with retry while server initializes the abstract socket
                self.state = .connecting(step: "Connecting video stream...")
                var vStream: AdbStream?
                var lastErr: Error?
                for attempt in 1...10 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    do {
                        vStream = try await conn.openStream(destination: "localabstract:scrcpy_\(scidHex)")
                        break
                    } catch {
                        lastErr = error
                        if attempt == 10 {
                            throw error
                        }
                    }
                }
                guard let videoStream = vStream else {
                    throw lastErr ?? AdbError.connectionFailed("Could not connect to video stream")
                }
                self.videoStream = videoStream

                // Connect Audio stream (if audio is enabled)
                var aStream: AdbStream?
                if self.audioEnabled {
                    self.state = .connecting(step: "Connecting audio stream...")
                    do {
                        aStream = try await conn.openStream(destination: "localabstract:scrcpy_\(scidHex)")
                        self.audioStream = aStream
                    } catch {
                        print("[ScrcpyClient] Failed to open audio stream: \(error)")
                    }
                }

                // Open Control stream
                self.state = .connecting(step: "Connecting control stream...")
                let cStream = try await conn.openStream(destination: "localabstract:scrcpy_\(scidHex)")
                self.controlStream = cStream

                self.state = .mirroring
                startStatsTimer()

                // Start streams processing
                self.startVideoProcessing(stream: videoStream)
                if let aStream = aStream {
                    self.startAudioProcessing(stream: aStream)
                }
                self.startControlProcessing(stream: cStream)

            } catch {
                self.state = .error(error.localizedDescription)
                self.stop()
            }
        }
    }

    private var ifCaseError: Bool {
        if case .error = state { return true }
        return false
    }

    private func startVideoProcessing(stream: AdbStream) {
        videoTask = Task.detached { [weak self] in
            var buffer = Data()
            var dummyByteHandled = false
            var deviceNameHandled = false
            var codecHandled = false

            for await chunk in stream.incomingData {
                buffer.append(chunk)

                // 1. Consume dummy byte if tunnel_forward
                if !dummyByteHandled {
                    guard !buffer.isEmpty else { continue }
                    buffer = Data(buffer.dropFirst())
                    dummyByteHandled = true
                }

                // 2. Read 64-byte Device Name
                if !deviceNameHandled {
                    guard buffer.count >= 64 else { continue }
                    let nameData = Data(buffer.prefix(64))
                    buffer = Data(buffer.dropFirst(64))
                    let name = String(data: nameData, encoding: .utf8)?
                        .trimmingCharacters(in: .controlCharacters) ?? "Android Device"
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.deviceName = name
                    }
                    deviceNameHandled = true
                }

                // 3. Read 4-byte Codec ID
                if !codecHandled {
                    guard buffer.count >= 4 else { continue }
                    _ = Data(buffer.prefix(4))
                    buffer = Data(buffer.dropFirst(4))
                    codecHandled = true
                }

                // 4. Read packets loop
                while buffer.count >= 12 {
                    guard let firstByte = buffer.first else { break }
                    let isSession = (firstByte & 0x80) != 0

                    if isSession {
                        // Session packet (12 bytes)
                        let metaData = Data(buffer.prefix(12))
                        if let sessionMeta = ScrcpySessionMeta(data: metaData) {
                            buffer = Data(buffer.dropFirst(12))
                            let w = sessionMeta.width
                            let h = sessionMeta.height
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.videoDimensions = CGSize(width: w, height: h)
                            }
                        } else {
                            buffer = Data(buffer.dropFirst(1))
                        }
                    } else {
                        // Media packet header (12 bytes)
                        let headerData = Data(buffer.prefix(12))
                        guard let header = ScrcpyMediaPacketHeader(data: headerData) else {
                            buffer = Data(buffer.dropFirst(1))
                            continue
                        }

                        let totalPacketLen = 12 + header.packetSize
                        guard buffer.count >= totalPacketLen else {
                            // Wait for full frame payload
                            break
                        }

                        let payload = Data(buffer.dropFirst(12).prefix(header.packetSize))
                        buffer = Data(buffer.dropFirst(totalPacketLen))

                        guard let client = self else { return }
                        client.decoder.decodePacket(
                            data: payload,
                            pts: header.pts,
                            isConfig: header.isConfig,
                            isKeyFrame: header.isKeyFrame
                        )
                    }
                }
            }
        }
    }

    private func startAudioProcessing(stream: AdbStream) {
        audioPlayer.start()
        audioTask = Task.detached { [weak self] in
            guard let self = self else { return }
            var buffer = Data()
            var codecHandled = false

            for await chunk in stream.incomingData {
                buffer.append(chunk)

                // 1. Read 4-byte Codec ID
                if !codecHandled {
                    guard buffer.count >= 4 else { continue }
                    let codecData = Data(buffer.prefix(4))
                    buffer = Data(buffer.dropFirst(4))
                    let codecId = codecData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    print(String(format: "[ScrcpyClient] Audio stream connected (Codec ID: 0x%08X)", codecId))
                    if codecId == 0 {
                        print("[ScrcpyClient] Audio recording unsupported or disabled by device")
                        return
                    }
                    codecHandled = true
                }

                // 2. Read audio packet loop (12-byte header + payload)
                while buffer.count >= 12 {
                    let headerData = Data(buffer.prefix(12))
                    guard let header = ScrcpyMediaPacketHeader(data: headerData) else {
                        buffer = Data(buffer.dropFirst(1))
                        continue
                    }

                    guard buffer.count >= 12 + header.packetSize else {
                        break // Wait for remaining audio payload
                    }

                    buffer = Data(buffer.dropFirst(12))
                    let audioData = Data(buffer.prefix(header.packetSize))
                    buffer = Data(buffer.dropFirst(header.packetSize))

                    self.audioPlayer.enqueue(data: audioData)
                    let ptsTime = CMTime(value: Int64(header.pts), timescale: 1_000_000)
                    self.recorder.appendAudioData(audioData, pts: ptsTime)
                }
            }
        }
    }

    private func startControlProcessing(stream: AdbStream) {
        controlTask = Task.detached { [weak self] in
            guard let self = self else { return }
            var buffer = Data()
            for await chunk in stream.incomingData {
                buffer.append(chunk)

                while !buffer.isEmpty {
                    if let result = ScrcpyDeviceMessage.deserialize(from: buffer) {
                        buffer = Data(buffer.dropFirst(result.bytesConsumed))
                        await self.handleDeviceMessage(result.message)
                    } else {
                        break
                    }
                }
            }
        }
    }

    private func handleDeviceMessage(_ msg: ScrcpyDeviceMessage) {
        switch msg {
        case .clipboard(let text):
            self.clipboardText = text
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        default:
            break
        }
    }

    /// Send a control message (touch, keycode, text, etc.) to the Android device
    public func send(controlMessage: ScrcpyControlMessage) {
        guard let stream = controlStream, stream.isOpen else { return }
        let data = controlMessage.serialize()
        Task {
            try? await stream.write(data)
        }
    }

    // Common screen navigation actions
    public func pressBack() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .back))
        send(controlMessage: .injectKeycode(action: .up, keycode: .back))
    }

    public func pressHome() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .home))
        send(controlMessage: .injectKeycode(action: .up, keycode: .home))
    }

    public func pressAppSwitch() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .appSwitch))
        send(controlMessage: .injectKeycode(action: .up, keycode: .appSwitch))
    }

    public func pressPower() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .power))
        send(controlMessage: .injectKeycode(action: .up, keycode: .power))
    }

    public func pressVolumeUp() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .volumeUp))
        send(controlMessage: .injectKeycode(action: .up, keycode: .volumeUp))
    }

    public func pressVolumeDown() {
        send(controlMessage: .injectKeycode(action: .down, keycode: .volumeDown))
        send(controlMessage: .injectKeycode(action: .up, keycode: .volumeDown))
    }

    public func injectText(_ text: String) {
        send(controlMessage: .injectText(text))
    }

    public func rotate() {
        send(controlMessage: .rotateDevice)
    }

    // Camera-specific actions
    public func toggleTorch() {
        isTorchOn.toggle()
        send(controlMessage: .cameraSetTorch(isTorchOn))
    }

    public func cameraZoomIn() {
        send(controlMessage: .cameraZoomIn)
    }

    public func cameraZoomOut() {
        send(controlMessage: .cameraZoomOut)
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentFps = self.decoder.currentFps
            }
        }
    }

    public func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        videoTask?.cancel()
        videoTask = nil
        audioTask?.cancel()
        audioTask = nil
        controlTask?.cancel()
        controlTask = nil
        audioPlayer.stop()

        Task {
            await videoStream?.close()
            await audioStream?.close()
            await controlStream?.close()
            await serverProcessStream?.close()
            adbConnection?.disconnect()
            adbConnection = nil

            self.state = .disconnected
            self.decoder.reset()
        }

        if recorder.isRecording {
            Task { [recorder] in
                try? await recorder.stopRecording()
            }
        }
    }

    // MARK: - Stream Recording
    public func startRecording(customFileName: String? = nil) {
        recorder.startRecording(source: videoSource, includeAudio: audioEnabled, customFileName: customFileName)
    }

    @discardableResult
    public func stopRecording() async throws -> URL? {
        return try await recorder.stopRecording()
    }

    private func loadBundledServerJar() -> Data? {
        let candidateNames: [(name: String, ext: String?)] = [
            ("scrcpy-server", "jar"),
            ("scrcpy-server", nil),
            ("scrcpy-server-v4.1", nil),
            ("scrcpy-server-v4.1", "jar")
        ]

        var bundles: [Bundle] = [Bundle.main, Bundle(for: ScrcpyClient.self)]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif

        for b in bundles {
            for cand in candidateNames {
                if let url = b.url(forResource: cand.name, withExtension: cand.ext),
                   let data = try? Data(contentsOf: url) {
                    return data
                }
            }
        }
        return nil
    }
}
