import SwiftUI
import Combine
import ScrcpyKit

public enum DiscoveryTab: String, CaseIterable {
    case mirror = "Screen"
    case camera = "Camera"
    case pair = "ADB Pair"
    case help = "Help"
}

@MainActor
public final class DeviceDiscoveryViewModel: ObservableObject {
    @Published public var currentTab: DiscoveryTab = .mirror
    @Published public var hostInput: String = "10.0.0.30"
    @Published public var portInput: String = "5555"

    // Pairing fields (Android 11+)
    @Published public var pairingPortInput: String = ""
    @Published public var pairingCodeInput: String = ""
    @Published public var isPairing: Bool = false
    @Published public var pairStatusMessage: String?
    @Published public var pairSuccess: Bool = false

    // Stream settings
    @Published public var selectedCameraFacing: ScrcpyCameraFacing = .back
    @Published public var selectedResolution: Int = 1920
    @Published public var selectedBitrateMbps: Double = 8.0
    @Published public var selectedFps: Int = 60
    @Published public var selectedCodec: ScrcpyVideoCodec = .h264
    @Published public var audioEnabled: Bool = false
    @Published public var stayAwake: Bool = true
    @Published public var showTouches: Bool = false
    @Published public var customServerArgs: String = ""
    @Published public var showAdvanced: Bool = false

    public let client: ScrcpyClient
    private var cancellables = Set<AnyCancellable>()

    public init(client: ScrcpyClient) {
        self.client = client
        client.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func connectDevice() {
        client.host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        client.port = UInt16(portInput) ?? 5555
        client.videoSource = (currentTab == .camera) ? .camera : .display
        client.cameraFacing = selectedCameraFacing
        client.videoCodec = selectedCodec
        client.maxSize = selectedResolution
        client.bitRate = Int(selectedBitrateMbps * 1_000_000)
        client.maxFps = selectedFps
        client.audioEnabled = audioEnabled
        client.stayAwake = stayAwake
        client.showTouches = showTouches
        client.customServerArgs = customServerArgs
        client.start()
    }

    public func pairDevice() {
        var host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.contains(":") {
            let parts = host.split(separator: ":")
            if parts.count == 2 {
                host = String(parts[0])
                if pairingPortInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pairingPortInput = String(parts[1])
                }
                hostInput = host
            }
        }

        guard !host.isEmpty else {
            pairStatusMessage = "Please enter the Android device IP address."
            pairSuccess = false
            return
        }

        guard let pPort = UInt16(pairingPortInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pairStatusMessage = "Please enter a valid pairing port from the popup (e.g. 37123)."
            pairSuccess = false
            return
        }

        let code = pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            pairStatusMessage = "Please enter the 6-digit pairing code."
            pairSuccess = false
            return
        }

        isPairing = true
        pairStatusMessage = "Pairing with Android device at \(host):\(pPort)..."
        pairSuccess = false

        Task {
            let result = await AdbPairService.pair(host: host, port: pPort, code: code)
            await MainActor.run {
                self.isPairing = false
                switch result {
                case .success:
                    self.pairSuccess = true
                    self.pairStatusMessage = "✓ Paired successfully!\nNow return to 'Screen' or 'Camera' tab, enter the connect port, and click Connect."
                case .failure(let err):
                    self.pairSuccess = false
                    self.pairStatusMessage = "Pairing failed: \(err)"
                }
            }
        }
    }
}

public struct DeviceDiscoveryView: View {
    @StateObject private var vm: DeviceDiscoveryViewModel

    public init(client: ScrcpyClient) {
        _vm = StateObject(wrappedValue: DeviceDiscoveryViewModel(client: client))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Branding
                headerView

                // Tab Switcher
                Picker("Mode", selection: $vm.currentTab) {
                    Label("Screen", systemImage: "iphone").tag(DiscoveryTab.mirror)
                    Label("Camera", systemImage: "camera.fill").tag(DiscoveryTab.camera)
                    Label("ADB Pair", systemImage: "link.badge.plus").tag(DiscoveryTab.pair)
                    Label("Guide", systemImage: "questionmark.circle").tag(DiscoveryTab.help)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)

                // Tab Content
                switch vm.currentTab {
                case .mirror, .camera:
                    connectionCard
                    qualityCard
                    advancedCard
                case .pair:
                    pairingCard
                case .help:
                    helpCard
                }
            }
            .padding(24)
            .frame(maxWidth: 540)
        }
        .frame(minWidth: 460)
        .background(Color(white: 0.08).ignoresSafeArea())
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 14) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scrcpy for iOS")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Native Ultra Low-Latency Android Screen & Camera Mirror")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Connection Card
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(vm.currentTab == .camera ? "Camera Stream Target" : "Target Android Device")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Spacer()
                if vm.currentTab == .camera {
                    Text("CAMERA MODE")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundColor(.yellow)
                        .cornerRadius(6)
                }
            }

            // IP Input
            VStack(alignment: .leading, spacing: 6) {
                Text("IP Address")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    TextField("192.168.1.150", text: $vm.hostInput)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .autocorrectionDisabled(true)
                        .disableTextInputAutocapitalization()
                    if !vm.hostInput.isEmpty {
                        Button(action: { vm.hostInput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(white: 0.14))
                .cornerRadius(10)
            }

            // Port Input
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Port")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Default 5555") {
                        vm.portInput = "5555"
                    }
                    .font(.caption2)
                    .foregroundColor(.blue)
                }

                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    TextField("5555", text: $vm.portInput)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                }
                .padding(10)
                .background(Color(white: 0.14))
                .cornerRadius(10)
            }

            // Camera lens selector if in camera mode
            if vm.currentTab == .camera {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera Lens")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Picker("Lens", selection: $vm.selectedCameraFacing) {
                        Text("Back Lens").tag(ScrcpyCameraFacing.back)
                        Text("Front Selfie Lens").tag(ScrcpyCameraFacing.front)
                        Text("External USB").tag(ScrcpyCameraFacing.external)
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Error display
            if case .error(let errMsg) = vm.client.state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errMsg)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }

            // Connect Button
            if case .connecting(let step) = vm.client.state {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(step)
                        .font(.footnote)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.6))
                .cornerRadius(12)
            } else {
                Button(action: { vm.connectDevice() }) {
                    HStack {
                        Spacer()
                        Image(systemName: vm.currentTab == .camera ? "camera.fill" : "play.fill")
                        Text(vm.currentTab == .camera ? "Launch Camera Stream" : "Connect & Mirror")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: vm.currentTab == .camera ? [.orange, .yellow] : [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
    }

    // MARK: - Quality Settings Card
    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stream Quality & Codec")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            // Codec & Framerate
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codec")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Codec", selection: $vm.selectedCodec) {
                        Text("H.264").tag(ScrcpyVideoCodec.h264)
                        Text("H.265 (HEVC)").tag(ScrcpyVideoCodec.h265)
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Framerate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("FPS", selection: $vm.selectedFps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Resolution
            VStack(alignment: .leading, spacing: 6) {
                Text("Max Resolution")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Resolution", selection: $vm.selectedResolution) {
                    Text("Native").tag(0)
                    Text("1080p").tag(1920)
                    Text("720p").tag(1280)
                    Text("800p").tag(800)
                }
                .pickerStyle(.segmented)
            }

            // Bitrate Slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bitrate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(vm.selectedBitrateMbps)) Mbps")
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                }
                Slider(value: $vm.selectedBitrateMbps, in: 2...20, step: 1)
                    .tint(.cyan)
            }

            Toggle(vm.currentTab == .camera ? "Forward Microphone Audio" : "Forward Device Audio", isOn: $vm.audioEnabled)
                .font(.caption.bold())
                .foregroundColor(.white)
        }
        .padding(18)
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
    }

    // MARK: - Advanced Scrcpy Flags Card
    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { withAnimation { vm.showAdvanced.toggle() } }) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                    Text("Advanced Scrcpy Flags")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: vm.showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if vm.showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Stay Awake (stay_awake=true)", isOn: $vm.stayAwake)
                    Toggle("Show Touch Dots (show_touches=true)", isOn: $vm.showTouches)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom Arguments (key=value):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("crop=1080:1080:0:0 angle=90", text: $vm.customServerArgs)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(Color(white: 0.1))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.top, 6)
            }
        }
        .padding(18)
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
    }

    // MARK: - ADB Pairing Card (Android 11+)
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wireless Pairing (Android 11+)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Pair once using a 6-digit Wi-Fi code")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("How to find your pairing code:")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Text("1. On Android: Settings > Developer Options > Wireless Debugging.\n2. Tap 'Pair device with pairing code'.\n3. Enter the IP address, pairing port, and 6-digit code shown in the popup dialog:")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.1))
            .cornerRadius(10)

            // Device IP Address
            VStack(alignment: .leading, spacing: 6) {
                Text("Device IP Address (from popup)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.green)
                    TextField("e.g. 192.168.1.150", text: $vm.hostInput)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .autocorrectionDisabled(true)
                        .disableTextInputAutocapitalization()
                    if !vm.hostInput.isEmpty {
                        Button(action: { vm.hostInput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(white: 0.14))
                .cornerRadius(10)
            }

            // Pairing Port & 6-Digit Pairing Code
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing Port (from popup)")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)
                        TextField("e.g. 37123", text: $vm.pairingPortInput)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)
                            .disableTextInputAutocapitalization()
                        if !vm.pairingPortInput.isEmpty {
                            Button(action: { vm.pairingPortInput = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(white: 0.14))
                    .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("6-Digit Code")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(.secondary)
                        TextField("e.g. 123456", text: $vm.pairingCodeInput)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)
                            .disableTextInputAutocapitalization()
                        if !vm.pairingCodeInput.isEmpty {
                            Button(action: { vm.pairingCodeInput = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(white: 0.14))
                    .cornerRadius(10)
                }
            }

            // Note explaining the two ports
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Android generates a temporary port specifically for pairing (shown inside the popup). Once paired, your regular connect port is shown on the main Wireless Debugging page.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)

            // Status message
            if let msg = vm.pairStatusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: vm.pairSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundColor(vm.pairSuccess ? .green : .orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(vm.pairSuccess ? .green : .white)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vm.pairSuccess ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // Pair Button
            Button(action: { vm.pairDevice() }) {
                HStack {
                    Spacer()
                    if vm.isPairing {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text(vm.isPairing ? "Pairing..." : "Pair with Android")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 12)
                .background(Color.green)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(vm.isPairing)
        }
        .padding(18)
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
    }

    // MARK: - Help Card
    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection Quick Guide")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 14) {
                guideSection(
                    title: "Method 1: Standard Port 5555 (Recommended)",
                    content: "1. Connect your Android device to a computer via USB once.\n2. Run: 'adb tcpip 5555' in terminal.\n3. Disconnect USB. Enter your Android IP and port 5555 in the app.\n4. When you connect, Android will prompt: 'Allow USB debugging?'. Tap Allow."
                )

                guideSection(
                    title: "Method 2: Wireless Debugging (Android 11+)",
                    content: "1. Ensure phone & iPad/Mac are on the same Wi-Fi.\n2. Go to Settings > Developer Options > Wireless Debugging.\n3. Open the 'ADB Pair' tab here, enter the pairing code and pairing port from 'Pair with pairing code'.\n4. Once paired, go back to the 'Screen' tab, enter the main Wireless Debugging port (shown on the main screen), and tap Connect."
                )
            }
        }
        .padding(18)
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
    }

    private func guideSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.blue)
            Text(content)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.1))
        .cornerRadius(10)
    }
}

fileprivate extension View {
    @ViewBuilder
    func disableTextInputAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
