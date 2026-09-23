import SwiftUI
import ScrcpyKit

#if canImport(AppKit)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

public struct RootContentView: View {
    @ObservedObject public var client: ScrcpyClient

    public init(client: ScrcpyClient) {
        self.client = client
    }

    public var body: some View {
        ZStack {
            DeviceDiscoveryView(client: client)
                .opacity(client.state == .mirroring ? 0 : 1)
                .allowsHitTesting(client.state != .mirroring)

            if client.state == .mirroring {
                MirrorSessionView(client: client)
                    .transition(.opacity)
            }
        }
        #if canImport(UIKit)
        .preferredColorScheme(.dark)
        #endif
    }
}

@main
public struct ScrcpyApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    private let client = ScrcpyClient()

    public init() {}

    public var body: some Scene {
        WindowGroup("Scrcpy iOS Client") {
            RootContentView(client: client)
                #if os(macOS)
                .frame(minWidth: 420, idealWidth: 480, minHeight: 680, idealHeight: 800)
                #endif
        }
    }
}
