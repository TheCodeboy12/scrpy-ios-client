import SwiftUI
import ScrcpyKit
#if canImport(Photos)
import Photos
#endif

public struct MirrorSessionView: View {
    @ObservedObject public var client: ScrcpyClient
    @ObservedObject private var recorder: StreamRecorder

    @State private var showTextInput: Bool = false
    @State private var textToInject: String = ""
    @State private var showControls: Bool = true
    @State private var showCopiedAlert: Bool = false
    @State private var recordedURL: URL? = nil
    @State private var recordingToastMessage: String? = nil
    @State private var showShareSheet: Bool = false
    @State private var showRecordingsGallery: Bool = false

    @AppStorage("scrcpy_show_nav_bar") private var showAndroidNavBar: Bool = true
    @AppStorage("scrcpy_auto_save_photos") private var autoSaveToPhotos: Bool = true
    @FocusState private var isTextFieldFocused: Bool

    public init(client: ScrcpyClient) {
        self.client = client
        self._recorder = ObservedObject(wrappedValue: client.recorder)
    }

    public var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

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
                    if showControls {
                        topHudBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Recording Toast / Notification Banner
                    if let message = recordingToastMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "video.fill")
                                .foregroundColor(.cyan)
                            Text(message)
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if recordedURL != nil {
                                Button(action: { showShareSheet = true }) {
                                    Text("Share")
                                        .font(.caption.bold())
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .shadow(radius: 6)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()

                    // Bottom Floating Action & Utility Bars
                    if showControls {
                        bottomControlsBar(isLandscape: isLandscape)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // Landscape Navigation Bar (Docked on Right Side)
                if showControls && showAndroidNavBar && client.videoSource == .display && isLandscape {
                    HStack {
                        Spacer()
                        androidNavBar(isVertical: true)
                            .padding(.trailing, 16)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .sheet(isPresented: $showTextInput) {
            NavigationStack {
                VStack(spacing: 20) {
                    Text("Type text to send directly to the Android device:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top)

                    HStack {
                        Image(systemName: "keyboard")
                            .foregroundColor(.blue)
                        TextField("Enter text here...", text: $textToInject)
                            .textFieldStyle(.plain)
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                sendInjectedText()
                            }
                        if !textToInject.isEmpty {
                            Button(action: { textToInject = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(Color(white: 0.15))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button(action: {
                            sendInjectedText()
                        }) {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text("Send Text")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(textToInject.isEmpty)

                        Button(action: {
                            sendInjectedText(keepOpen: true)
                        }) {
                            Text("Send & Continue")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(white: 0.25))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(textToInject.isEmpty)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .navigationTitle("Android Keyboard Input")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showTextInput = false
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isTextFieldFocused = true
                    }
                }
            }
            .presentationDetents([.height(240), .medium])
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showShareSheet) {
            if let url = recordedURL {
                ShareSheetView(url: url)
            }
        }
        #endif
        .sheet(isPresented: $showRecordingsGallery) {
            RecordingsListView()
        }
        .alert("Clipboard Copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS clipboard contents sent to Android device.")
        }
        #if os(iOS)
        .statusBarHidden(!showControls)
        #endif
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }

    // MARK: - Top HUD Bar
    private var topHudBar: some View {
        HStack(spacing: 12) {
            // Back to Discovery Button
            Button(action: { client.stop() }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.85))
            }

            // Connection Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text(client.videoSource == .camera ? "Camera Live" : (client.deviceName.isEmpty ? "Connected" : client.deviceName))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }

                if let dims = client.videoDimensions {
                    Text("\(Int(dims.width)) × \(Int(dims.height))")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer()

            // Recording Indicator Badge (when active)
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC \(formattedDuration(recorder.recordingDuration))")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.85))
                .cornerRadius(12)
            }

            // Audio Indicator
            if client.audioEnabled {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // FPS Badge
            Text(String(format: "%.1f FPS", client.currentFps))
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .foregroundColor(.white)

            // Recordings Gallery Button
            Button(action: { showRecordingsGallery = true }) {
                Image(systemName: "film.stack")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.85))
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

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
    }

    // MARK: - Bottom Controls Bar
    private func bottomControlsBar(isLandscape: Bool) -> some View {
        VStack(spacing: 8) {
            // Camera Control Bar (only when in camera mode)
            if client.videoSource == .camera {
                HStack(spacing: 20) {
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

                    // Recording Action Button
                    Button(action: { toggleRecording() }) {
                        if recorder.isRecording {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 10, height: 10)
                                Text(formattedDuration(recorder.recordingDuration))
                            }
                            .foregroundColor(.red)
                        } else {
                            Label("Record", systemImage: "record.circle")
                                .foregroundColor(.red)
                        }
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
                // Recording button in utility bar
                Button(action: { toggleRecording() }) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 16))
                        .foregroundColor(recorder.isRecording ? .red : .white.opacity(0.85))
                }

                if client.videoSource == .display {
                    // Keyboard input button
                    Button(action: { showTextInput = true }) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 16))
                    }

                    // Clipboard sync button
                    Button(action: { syncClipboard() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 16))
                    }

                    // Toggle Android Navigation Bar button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAndroidNavBar.toggle()
                        }
                    }) {
                        Image(systemName: showAndroidNavBar ? "menubar.dock.rectangle" : "menubar.rectangle")
                            .font(.system(size: 16))
                            .foregroundColor(showAndroidNavBar ? .cyan : .white.opacity(0.85))
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

            // Portrait Android 3-Button Navigation Bar (Horizontal)
            if client.videoSource == .display && !isLandscape && showAndroidNavBar {
                androidNavBar(isVertical: false)
            }
        }
        .padding(.bottom, isLandscape ? 8 : 20)
    }

    // MARK: - Android 3-Button Navigation Bar
    @ViewBuilder
    private func androidNavBar(isVertical: Bool) -> some View {
        if isVertical {
            VStack(spacing: 24) {
                // Back
                Button(action: { client.pressBack() }) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                }

                // Home
                Button(action: { client.pressHome() }) {
                    Circle()
                        .stroke(Color.white, lineWidth: 2.2)
                        .frame(width: 18, height: 18)
                        .frame(width: 44, height: 44)
                }

                // App Switcher / Recents
                Button(action: { client.pressAppSwitch() }) {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white, lineWidth: 2.2)
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44)
                }
            }
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial)
            .cornerRadius(22)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
        } else {
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

    // MARK: - Actions
    private func toggleRecording() {
        if recorder.isRecording {
            Task {
                do {
                    if let url = try await client.stopRecording() {
                        recordedURL = url
                        if autoSaveToPhotos {
                            #if canImport(Photos)
                            do {
                                try await StreamRecorder.saveToPhotos(fileURL: url)
                                showToast("Saved to Photos & Files!")
                            } catch {
                                showToast("Saved to Files: \(url.lastPathComponent)")
                            }
                            #else
                            showToast("Saved to Files: \(url.lastPathComponent)")
                            #endif
                        } else {
                            showToast("Saved to Files: \(url.lastPathComponent)")
                        }
                    }
                } catch {
                    showToast("Recording error: \(error.localizedDescription)")
                }
            }
        } else {
            client.startRecording()
            showToast("Recording armed (waiting for frame)...")
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            recordingToastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation {
                    if self.recordingToastMessage == message {
                        self.recordingToastMessage = nil
                    }
                }
            }
        }
    }

    private func formattedDuration(_ sec: TimeInterval) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func syncClipboard() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string, !text.isEmpty {
            client.send(controlMessage: .setClipboard(sequence: 1, text: text, paste: false))
            showCopiedAlert = true
        }
        #endif
    }

    private func sendInjectedText(keepOpen: Bool = false) {
        guard !textToInject.isEmpty else { return }
        client.injectText(textToInject)
        textToInject = ""
        if !keepOpen {
            showTextInput = false
        }
    }
}

// MARK: - Share Sheet View
#if canImport(UIKit)
import UIKit

private struct ShareSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
