# Scrcpy-iOS (ScrcpyKit) 📱✨

A high-performance, native iOS/iPadOS client for **[scrcpy](https://github.com/Genymobile/scrcpy)** built in pure Swift.

Unlike older ports (such as `wsvn53/scrcpy-ios`) that compile desktop C code, SDL2, and FFmpeg for iOS, **Scrcpy-iOS** is built from the ground up for Apple platforms using **Apple VideoToolbox**, **Network.framework**, and **SwiftUI**.

---

## Why This Client vs Older Ports?

| Feature | `wsvn53/scrcpy-ios` (Old Port) | **Scrcpy-iOS (This Project)** |
|---|---|---|
| **Architecture** | Desktop C / SDL2 / FFmpeg / libssh | **Pure Swift + VideoToolbox + Network.framework** |
| **Video Decoding** | FFmpeg software / CPU heavy | **Hardware VideoToolbox (Zero-copy GPU direct)** |
| **Latency** | 100ms - 250ms (noticeable lag) | **< 20ms (butter-smooth real-time)** |
| **Battery & Thermals** | Extreme heat & battery drain | **Minimal CPU usage, cool and efficient** |
| **Touch Controls** | Clunky SDL mouse emulation | **Native iOS multi-touch, drag, fling & gestures** |
| **Android Navigation** | Limited / desktop keyboard shortcuts | **Dedicated floating Android Navigation Bar** |
| **ADB Connection** | Requires external bridge or PC | **Built-in Pure Swift ADB Client over Wi-Fi** |
| **Scrcpy Compatibility** | Stuck on old scrcpy v1.x/v2 | **Compatible with scrcpy v2.x / v3.x / v4.x** |
| **Binary Size** | ~100+ MB with FFmpeg & SDL | **~5 MB total app bundle** |

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Scrcpy-iOS SwiftUI App                          │
│        (DeviceDiscoveryView, MirrorSessionView, SettingsView)          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                              ScrcpyKit                                 │
│                                                                        │
│   ┌─────────────────────────────┐     ┌────────────────────────────┐   │
│   │        ScrcpyClient         │◄───►│     TouchOverlayView       │   │
│   │  (Connection Coordinator)   │     │ (Multi-touch & Gestures)   │   │
│   └──────────────┬──────────────┘     └─────────────┬──────────────┘   │
│                  │                                  │                  │
│   ┌──────────────┴──────────────┐     ┌─────────────▼──────────────┐   │
│   │    VideoToolboxDecoder      │     │    ScrcpyControlMessage    │   │
│   │ (AVSampleBufferDisplayLayer)│     │(Touch, Keys, Text, Clipbd) │   │
│   └──────────────┬──────────────┘     └─────────────┬──────────────┘   │
│                  │                                  │                  │
│   ┌──────────────▼──────────────────────────────────▼──────────────┐   │
│   │                         AdbConnection                          │   │
│   │  (Pure Swift ADB: Handshake, RSA Auth, SYNC push, Multiplex)   │   │
│   └──────────────────────────────┬─────────────────────────────────┘   │
└──────────────────────────────────┼─────────────────────────────────────┘
                                   │ TCP (Wi-Fi: Port 5555)
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                            Android Device                              │
│       (/data/local/tmp/scrcpy-server.jar -> MediaCodec H.264/H.265)    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Features

- ⚡ **Near-Zero Latency**: Direct hardware decoding into `AVSampleBufferDisplayLayer` via Apple Silicon Media Engine.
- 📷 **Direct Android Camera Streaming (`--video-source=camera`)**:
  - Stream directly from Android's **Back**, **Front**, or **External USB** camera lenses without displaying the screen.
  - Interactive camera controls: **Flashlight/Torch toggle**, **Zoom In/Out**, and microphone audio forwarding.
  - Support for high-speed camera capture (`camera_high_speed=true`).
- 📶 **Autonomous Wi-Fi Connection**: iPhone connects directly to Android over Wi-Fi. It authenticates with RSA, automatically uploads `scrcpy-server.jar`, and launches screen mirroring—no computer required!
- 👆 **Native iOS Touch & Gestures**: Smooth swipe, drag, tap, and multi-finger gestures mapped with sub-pixel precision to Android screen coordinates.
- 🎮 **On-Screen Android Navigation Bar**:
  - ◀ **Back** (Android `AKEYCODE_BACK`)
  - ⌂ **Home** (Android `AKEYCODE_HOME`)
  - ▢ **Recents / App Switcher** (Android `AKEYCODE_APP_SWITCH`)
  - ⚡ **Power** (Screen On / Off / Sleep)
  - 🔊 **Volume Up / Down**
  - 🔄 **Rotate Screen**
  - ⌨ **Direct Text Injection**: Type using iOS keyboard directly into any focused Android text field.
  - 📋 **Bidirectional Clipboard Sync**: Seamless copy-paste between iOS and Android.
- ⚙ **Configurable Streaming & Flags**:
  - Codecs: **H.264** or **H.265 (HEVC)**
  - Resolutions: Native, 1080p, 720p, 800p
  - Bitrate: 2 Mbps to 20 Mbps
  - Framerate: 30 FPS, 60 FPS, 120 FPS (iPad Pro / iPhone ProMotion)
  - Audio Forwarding toggle (Android 11+)
  - **Arbitrary Custom Server Flags**: Pass any option such as `crop=1080:1080:0:0`, `angle=90`, or `stay_awake=true`.
- 📊 **Real-Time HUD**: Live FPS counter, active resolution, and connection state.

---

## Quick Start: Connecting to an Android Device

### 1. Prepare your Android Device
1. Open **Settings** > **About Phone** and tap **Build Number** 7 times to enable **Developer Options**.
2. Go to **Settings** > **Developer Options**:
   - Turn ON **USB Debugging**.
   - If available (Android 11+), turn ON **Wireless Debugging**.
3. If connecting via standard TCP/IP port 5555, enable it once using a computer or Termux:
   ```bash
   adb tcpip 5555
   ```
4. Note your Android device's local IP address (e.g., `192.168.1.150` in **Settings > Wi-Fi**).

### 2. Connect from iOS
1. Open **Scrcpy iOS** on your iPhone or iPad.
2. Enter the Android device's IP address (port `5555`).
3. Tap **Connect & Mirror**.
4. On your Android device, accept the prompt:
   > *"Allow USB debugging? The computer's RSA key fingerprint is..."*
   > Check *"Always allow from this computer"* and tap **Allow**.
5. The Android screen appears immediately with butter-smooth live mirroring!

---

## Running and Building the Code

### Run Automated Tests
```bash
swift run ScrcpyTests
```
Verifies ADB framing, RSA key generation, Android public key structuring, scrcpy protocol packets, touch coordinate serialization, and NALU conversions.

### Open in Xcode
You can open the project directly in Xcode:
```bash
open Package.swift
```
Select the **ScrcpyApp** scheme, pick your connected iPhone, iPad, or iOS Simulator, and press **Run** (`⌘R`).

---

## Project Structure

```
├── Package.swift                             # SwiftPM configuration
├── Sources/
│   ├── ScrcpyKit/                            # Reusable Core Framework
│   │   ├── Adb/
│   │   │   ├── AdbMessage.swift              # ADB wire protocol packets
│   │   │   ├── AdbCrypto.swift               # RSA-2048 & Android key formatting
│   │   │   ├── AdbConnection.swift           # TCP transport via Network.framework
│   │   │   ├── AdbStream.swift               # Multiplexed channel stream
│   │   │   └── AdbSyncService.swift          # File push protocol (sync:)
│   │   ├── Protocol/
│   │   │   ├── ScrcpyProtocol.swift          # Codecs, headers, session meta
│   │   │   ├── ScrcpyControlMessage.swift    # Touch, keycode, text, scroll
│   │   │   ├── ScrcpyDeviceMessage.swift     # Clipboard sync from device
│   │   │   └── Data+Binary.swift             # Safe endian binary serialization
│   │   ├── Video/
│   │   │   ├── NaluParser.swift              # Annex-B parser & AVCC conversion
│   │   │   ├── VideoToolboxDecoder.swift     # Apple hardware decoder
│   │   │   └── ScrcpyVideoView.swift         # AVSampleBufferDisplayLayer view
│   │   └── Session/
│   │       ├── ScrcpyClient.swift            # High-level session coordinator
│   │       └── GestureController.swift       # iOS multi-touch event overlay
│   ├── ScrcpyApp/                            # iOS Application Target
│   │   ├── ScrcpyApp.swift                   # SwiftUI app entry point
│   │   ├── Views/
│   │   │   ├── DeviceDiscoveryView.swift     # Connection dashboard & settings
│   │   │   └── MirrorSessionView.swift       # Fullscreen mirror with controls
│   │   └── Resources/
│   │       ├── scrcpy-server                 # Bundled official scrcpy-server binary
│   │       └── Info.plist                    # iOS permissions & Bonjour configuration
│   └── ScrcpyTests/                          # Verification Test Runner
│       └── main.swift                        # Automated test suite
└── Tests/ScrcpyKitTests/                     # XCTest unit test suites
```

---

## License
MIT License. `scrcpy-server` is Apache 2.0 (by Genymobile).
