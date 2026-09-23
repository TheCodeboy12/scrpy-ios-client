import SwiftUI
import Combine
import ScrcpyKit

public enum DiscoveryTab: String, CaseIterable, Identifiable {
    case mirror = "Screen"
    case camera = "Camera"
    case pair = "ADB Pair"
    case help = "Guide"

    public var id: String { rawValue }
}

@MainActor
public final class DeviceDiscoveryViewModel: ObservableObject {
    @ObservedObject public var profileManager = ProfileManager.shared

    // Pairing runtime state
    @Published public var isPairing: Bool = false
    @Published public var pairStatusMessage: String?
    @Published public var pairSuccess: Bool = false

    // Modals
    @Published public var isRenamingDevice: Bool = false
    @Published public var renamingDeviceName: String = ""
    @Published public var isAddingDevice: Bool = false
    @Published public var newDeviceName: String = ""
    @Published public var newDeviceHost: String = ""

    public let client: ScrcpyClient
    private var cancellables = Set<AnyCancellable>()

    public init(client: ScrcpyClient) {
        self.client = client
        client.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.objectWillChange.send()
                if case .mirroring = self.client.state {
                    self.profileManager.recordSuccessfulConnection(
                        host: self.client.host,
                        port: self.client.port,
                        deviceName: self.client.deviceName
                    )
                }
            }
            .store(in: &cancellables)

        profileManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func connectDevice(mode: DiscoveryTab) {
        let profile = profileManager.activeProfile
        client.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        client.port = profile.port
        client.videoSource = (mode == .camera) ? .camera : .display
        client.cameraFacing = profile.cameraFacing
        client.videoCodec = profile.codec
        client.maxSize = profile.resolution
        client.bitRate = Int(profile.bitrateMbps * 1_000_000)
        client.maxFps = profile.fps
        client.audioEnabled = profile.audioEnabled
        client.stayAwake = profile.stayAwake
        client.showTouches = profile.showTouches
        client.customServerArgs = profile.customServerArgs
        client.start()
    }

    public func quickConnect(to profile: ConnectionProfile, mode: DiscoveryTab) {
        profileManager.selectProfile(profile)
        connectDevice(mode: mode)
    }

    public func pairDevice(hostInput: String, portInput: String, codeInput: String) {
        var host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            host = profileManager.activeProfile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if host.contains(":") {
            let parts = host.split(separator: ":")
            if parts.count == 2 {
                host = String(parts[0])
            }
        }

        guard !host.isEmpty else {
            pairStatusMessage = "Please enter the Android device IP address."
            pairSuccess = false
            return
        }

        guard let pPort = UInt16(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pairStatusMessage = "Please enter a valid pairing port from the popup (e.g. 37123)."
            pairSuccess = false
            return
        }

        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    // Also update active profile host so user doesn't have to retype
                    self.profileManager.activeProfile.host = host
                    self.profileManager.saveCurrentState()
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
    @ObservedObject private var profileManager = ProfileManager.shared

    // Guaranteed persistence across app launches & screen changes via AppStorage
    @AppStorage("scrcpy_selected_tab") private var currentTab: DiscoveryTab = .mirror
    @AppStorage("scrcpy_pairing_host") private var pairingHostInput: String = ""
    @AppStorage("scrcpy_pairing_port") private var pairingPortInput: String = ""
    @AppStorage("scrcpy_pairing_code") private var pairingCodeInput: String = ""
    @AppStorage("scrcpy_show_advanced") private var showAdvanced: Bool = false

    public init(client: ScrcpyClient) {
        _vm = StateObject(wrappedValue: DeviceDiscoveryViewModel(client: client))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Branding
                headerView

                // Tab Switcher (Screen, Camera, ADB Pair, Guide)
                Picker("Mode", selection: $currentTab) {
                    Label("Screen", systemImage: "iphone").tag(DiscoveryTab.mirror)
                    Label("Camera", systemImage: "camera.fill").tag(DiscoveryTab.camera)
                    Label("ADB Pair", systemImage: "link.badge.plus").tag(DiscoveryTab.pair)
                    Label("Guide", systemImage: "questionmark.circle").tag(DiscoveryTab.help)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)

                // Tab Content
                switch currentTab {
                case .mirror, .camera:
                    savedDevicesSection
                    connectionCard
                    qualityCard
                    advancedCard
                case .pair:
                    pairingCard
                case .help:
                    helpCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08).ignoresSafeArea())
        .onAppear {
            if pairingHostInput.isEmpty {
                pairingHostInput = profileManager.activeProfile.host
            }
        }
        .onChange(of: profileManager.activeProfile) { _ in
            profileManager.saveCurrentState()
        }
        .alert("Rename Device Profile", isPresented: $vm.isRenamingDevice) {
            TextField("Device Name", text: $vm.renamingDeviceName)
            Button("Save") {
                vm.profileManager.renameProfile(id: vm.profileManager.activeProfile.id, newName: vm.renamingDeviceName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a recognizable name for this Android device.")
        }
        .alert("Add Android Device", isPresented: $vm.isAddingDevice) {
            TextField("Name (e.g. Living Room TV)", text: $vm.newDeviceName)
            TextField("IP Address (e.g. 192.168.1.150)", text: $vm.newDeviceHost)
            Button("Add Device") {
                _ = vm.profileManager.createNewProfile(name: vm.newDeviceName, host: vm.newDeviceHost)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add a new Android device profile with custom connection preferences.")
        }
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

    // MARK: - Saved Devices Section
    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved Devices", systemImage: "tv.and.mediabox")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    vm.newDeviceName = ""
                    vm.newDeviceHost = ""
                    vm.isAddingDevice = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Device")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.blue)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(profileManager.profiles) { profile in
                        let isSelected = profile.id == profileManager.activeProfile.id
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "tv.fill")
                                    .font(.title3)
                                    .foregroundColor(isSelected ? .cyan : .secondary)

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.cyan)
                                        .font(.caption)
                                }
                            }

                            Text(profile.name)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text("\(profile.host):\(String(profile.port))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            HStack {
                                Button(action: {
                                    vm.renamingDeviceName = profile.name
                                    profileManager.selectProfile(profile)
                                    vm.isRenamingDevice = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(6)
                                        .background(Color(white: 0.22))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)

                                if profileManager.profiles.count > 1 {
                                    Button(action: {
                                        profileManager.deleteProfile(id: profile.id)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.caption2)
                                            .foregroundColor(.red.opacity(0.8))
                                            .padding(6)
                                            .background(Color(white: 0.22))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer()

                                Button(action: {
                                    vm.quickConnect(to: profile, mode: currentTab)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill")
                                        Text("Connect")
                                    }
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isSelected ? Color.blue : Color(white: 0.25))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                        .frame(width: 175)
                        .background(isSelected ? Color.blue.opacity(0.18) : Color(white: 0.12))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? Color.blue : Color(white: 0.2), lineWidth: isSelected ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            profileManager.selectProfile(profile)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Connection Card
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTab == .camera ? "Camera Stream Target" : "Target Android Device")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Profile: \(profileManager.activeProfile.name)")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
                Spacer()
                Button(action: {
                    vm.renamingDeviceName = profileManager.activeProfile.name
                    vm.isRenamingDevice = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Rename")
                    }
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.18))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
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
                    TextField("192.168.1.150", text: $profileManager.activeProfile.host)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .autocorrectionDisabled(true)
                        .disableTextInputAutocapitalization()
                    if !profileManager.activeProfile.host.isEmpty {
                        Button(action: { profileManager.activeProfile.host = "" }) {
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
                        profileManager.activeProfile.port = 5555
                    }
                    .font(.caption2)
                    .foregroundColor(.blue)
                }

                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    TextField("5555", text: Binding(
                        get: { profileManager.activeProfile.port == 0 ? "" : String(profileManager.activeProfile.port) },
                        set: {
                            let digits = $0.filter { $0.isNumber }
                            if let val = UInt16(digits) {
                                profileManager.activeProfile.port = val
                            } else if digits.isEmpty {
                                profileManager.activeProfile.port = 0
                            }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                }
                .padding(10)
                .background(Color(white: 0.14))
                .cornerRadius(10)
            }

            // Camera lens selector if in camera mode
            if currentTab == .camera {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera Lens")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Picker("Lens", selection: $profileManager.activeProfile.cameraFacing) {
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
                Button(action: { vm.connectDevice(mode: currentTab) }) {
                    HStack {
                        Spacer()
                        Image(systemName: currentTab == .camera ? "camera.fill" : "play.fill")
                        Text(currentTab == .camera ? "Launch Camera Stream" : "Connect & Mirror")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: currentTab == .camera ? [.orange, .yellow] : [.blue, .cyan],
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
            Text("Stream Quality & Preferences (Saved per Profile)")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            // Codec & Framerate
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codec")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Codec", selection: $profileManager.activeProfile.codec) {
                        Text("H.264").tag(ScrcpyVideoCodec.h264)
                        Text("H.265 (HEVC)").tag(ScrcpyVideoCodec.h265)
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Framerate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("FPS", selection: $profileManager.activeProfile.fps) {
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
                Picker("Resolution", selection: $profileManager.activeProfile.resolution) {
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
                    Text("\(Int(profileManager.activeProfile.bitrateMbps)) Mbps")
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                }
                Slider(value: $profileManager.activeProfile.bitrateMbps, in: 2...20, step: 1)
                    .tint(.cyan)
            }

            // Audio Forwarding Toggle
            Toggle(
                currentTab == .camera ? "Forward Microphone Audio" : "Forward Device Audio",
                isOn: $profileManager.activeProfile.audioEnabled
            )
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
            Button(action: { withAnimation { showAdvanced.toggle() } }) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                    Text("Advanced Scrcpy Flags")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Stay Awake (stay_awake=true)", isOn: $profileManager.activeProfile.stayAwake)
                    Toggle("Show Touch Dots (show_touches=true)", isOn: $profileManager.activeProfile.showTouches)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom Arguments (key=value):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("crop=1080:1080:0:0 angle=90", text: $profileManager.activeProfile.customServerArgs)
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

            // Device IP Address (Auto-saved)
            VStack(alignment: .leading, spacing: 6) {
                Text("Device IP Address (from popup)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.green)
                    TextField("e.g. 192.168.1.150", text: $pairingHostInput)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .autocorrectionDisabled(true)
                        .disableTextInputAutocapitalization()
                    if !pairingHostInput.isEmpty {
                        Button(action: { pairingHostInput = "" }) {
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

            // Pairing Port & 6-Digit Pairing Code (Auto-saved)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing Port (from popup)")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)
                        TextField("e.g. 37123", text: $pairingPortInput)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)
                            .disableTextInputAutocapitalization()
                        if !pairingPortInput.isEmpty {
                            Button(action: { pairingPortInput = "" }) {
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
                        TextField("e.g. 123456", text: $pairingCodeInput)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)
                            .disableTextInputAutocapitalization()
                        if !pairingCodeInput.isEmpty {
                            Button(action: { pairingCodeInput = "" }) {
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
            Button(action: {
                vm.pairDevice(hostInput: pairingHostInput, portInput: pairingPortInput, codeInput: pairingCodeInput)
            }) {
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
