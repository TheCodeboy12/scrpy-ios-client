import SwiftUI
import ScrcpyKit

@MainActor
public final class MirrorSessionViewModel: ObservableObject {
    @Published public var showTextInput: Bool = false
    @Published public var textToInject: String = ""
    @Published public var showControls: Bool = true
    @Published public var showCopiedAlert: Bool = false

    public let client: ScrcpyClient

    public init(client: ScrcpyClient) {
        self.client = client
    }

    public func syncClipboard() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string, !text.isEmpty {
            client.send(controlMessage: .setClipboard(sequence: 1, text: text, paste: false))
            showCopiedAlert = true
        }
        #endif
    }

    public func sendInjectedText() {
        client.injectText(textToInject)
        textToInject = ""
        showTextInput = false
    }
}

public struct MirrorSessionView: View {
    @ObservedObject public var client: ScrcpyClient
    @ObservedObject public var vm: MirrorSessionViewModel

    public init(client: ScrcpyClient) {
        self.client = client
        self.vm = MirrorSessionViewModel(client: client)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video Stream Layer
            ScrcpyVideoView(session: client)
                .ignoresSafeArea()

            // Native Touch Event Interception Layer (only in display mode)
            #if canImport(UIKit)
            if client.videoSource == .display {
                TouchOverlayRepresentable(session: client)
                    .ignoresSafeArea()
            }
            #endif

            // Top HUD Bar
            VStack {
                if vm.showControls {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if client.videoSource == .camera {
                                    Image(systemName: "camera.fill")
                                        .foregroundColor(.yellow)
                                }
                                Text(client.deviceName.isEmpty ? "Android Device" : client.deviceName)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                            }
                            if let dim = client.videoDimensions {
                                Text("\(Int(dim.width)) × \(Int(dim.height))")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }

                        Spacer()

                        // FPS Badge
                        Text(String(format: "%.1f FPS", client.currentFps))
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                            .foregroundColor(.white)

                        // Disconnect Button
                        Button(action: { client.stop() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.7), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                // Floating Action & Navigation Bar
                if vm.showControls {
                    VStack(spacing: 8) {
                        // Camera Control Bar (only when in camera mode)
                        if client.videoSource == .camera {
                            HStack(spacing: 24) {
                                Button(action: { client.cameraZoomOut() }) {
                                    Label("Zoom -", systemImage: "minus.magnifyingglass")
                                }

                                Button(action: { client.cameraZoomIn() }) {
                                    Label("Zoom +", systemImage: "plus.magnifyingglass")
                                }

                                Button(action: { client.toggleTorch() }) {
                                    Label(client.isTorchOn ? "Torch On" : "Torch Off", systemImage: client.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                        .foregroundColor(client.isTorchOn ? .yellow : .white)
                                }
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                        }

                        // Utility Bar
                        HStack(spacing: 16) {
                            if client.videoSource == .display {
                                Button(action: { vm.showTextInput = true }) {
                                    Image(systemName: "keyboard")
                                        .font(.system(size: 16))
                                }

                                Button(action: { vm.syncClipboard() }) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 16))
                                }
                            }

                            Button(action: { client.rotate() }) {
                                Image(systemName: "rotate.right")
                                    .font(.system(size: 16))
                            }

                            Button(action: { client.pressVolumeDown() }) {
                                Image(systemName: "speaker.minus")
                                    .font(.system(size: 16))
                            }

                            Button(action: { client.pressVolumeUp() }) {
                                Image(systemName: "speaker.plus")
                                    .font(.system(size: 16))
                            }

                            Button(action: { client.pressPower() }) {
                                Image(systemName: "power")
                                    .font(.system(size: 16))
                            }
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)

                        // Android 3-Button Navigation Bar (for display mirroring)
                        if client.videoSource == .display {
                            HStack(spacing: 40) {
                                // Back
                                Button(action: { client.pressBack() }) {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 20, weight: .bold))
                                        .frame(width: 44, height: 44)
                                }

                                // Home
                                Button(action: { client.pressHome() }) {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2.5)
                                        .frame(width: 20, height: 20)
                                        .frame(width: 44, height: 44)
                                }

                                // App Switcher / Recents
                                Button(action: { client.pressAppSwitch() }) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white, lineWidth: 2.5)
                                        .frame(width: 18, height: 18)
                                        .frame(width: 44, height: 44)
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(24)
                        }
                    }
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $vm.showTextInput) {
            NavigationStack {
                VStack(spacing: 20) {
                    Text("Type text to send directly to the Android device:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("Enter text here...", text: $vm.textToInject)
                        .textFieldStyle(.roundedBorder)
                        .padding()

                    Button(action: { vm.sendInjectedText() }) {
                        Text("Send Text")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)
                .navigationTitle("Keyboard Input")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { vm.showTextInput = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onTapGesture(count: 3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                vm.showControls.toggle()
            }
        }
    }
}
