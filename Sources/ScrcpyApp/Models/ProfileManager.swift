import Foundation
import Combine
import ScrcpyKit

@MainActor
public final class ProfileManager: ObservableObject {
    public static let shared = ProfileManager()

    private let profilesKey = "scrcpy_saved_profiles_v2"
    private let activeIdKey = "scrcpy_active_profile_id_v2"

    @Published public var profiles: [ConnectionProfile] = []
    @Published public var activeProfile: ConnectionProfile {
        didSet {
            saveCurrentState()
        }
    }

    private init() {
        // 1. Try loading saved profiles
        var loadedProfiles: [ConnectionProfile] = []
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data),
           !decoded.isEmpty {
            loadedProfiles = decoded
        }

        // 2. Also check fallback v1 key
        if loadedProfiles.isEmpty,
           let data = UserDefaults.standard.data(forKey: "scrcpy_saved_profiles_v1"),
           let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data),
           !decoded.isEmpty {
            loadedProfiles = decoded
        }

        // 3. Fallback to individual stored keys or standard default
        if loadedProfiles.isEmpty {
            let savedHost = UserDefaults.standard.string(forKey: "scrcpy_active_host") ?? "10.0.0.30"
            let savedPort = UInt16(UserDefaults.standard.integer(forKey: "scrcpy_active_port"))
            let savedRes = UserDefaults.standard.integer(forKey: "scrcpy_active_resolution")
            let savedBitrate = UserDefaults.standard.double(forKey: "scrcpy_active_bitrate")
            let savedFps = UserDefaults.standard.integer(forKey: "scrcpy_active_fps")
            let savedAudio = UserDefaults.standard.object(forKey: "scrcpy_active_audio") as? Bool ?? true

            let defaultProfile = ConnectionProfile(
                name: "Living Room Device",
                host: savedHost.isEmpty ? "10.0.0.30" : savedHost,
                port: savedPort > 0 ? savedPort : 5555,
                resolution: savedRes > 0 ? savedRes : 1920,
                bitrateMbps: savedBitrate > 0 ? savedBitrate : 8.0,
                fps: savedFps > 0 ? savedFps : 60,
                audioEnabled: savedAudio
            )
            loadedProfiles = [defaultProfile]
        }

        self.profiles = loadedProfiles

        // 4. Restore active profile
        if let savedActiveIdString = UserDefaults.standard.string(forKey: activeIdKey),
           let savedActiveId = UUID(uuidString: savedActiveIdString),
           let found = loadedProfiles.first(where: { $0.id == savedActiveId }) {
            self.activeProfile = found
        } else {
            self.activeProfile = loadedProfiles[0]
        }
    }

    public func selectProfile(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            self.activeProfile = profiles[index]
            UserDefaults.standard.set(profile.id.uuidString, forKey: activeIdKey)
            UserDefaults.standard.synchronize()
        }
    }

    public func selectProfile(id: UUID) {
        if let found = profiles.first(where: { $0.id == id }) {
            self.activeProfile = found
            UserDefaults.standard.set(id.uuidString, forKey: activeIdKey)
            UserDefaults.standard.synchronize()
        }
    }

    public func saveCurrentState() {
        // Update the active profile within the array
        if let index = profiles.firstIndex(where: { $0.id == activeProfile.id }) {
            profiles[index] = activeProfile
        } else {
            profiles.append(activeProfile)
        }

        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfile.id.uuidString, forKey: activeIdKey)

        // Save individual fallback keys for guaranteed persistence
        UserDefaults.standard.set(activeProfile.host, forKey: "scrcpy_active_host")
        UserDefaults.standard.set(Int(activeProfile.port), forKey: "scrcpy_active_port")
        UserDefaults.standard.set(activeProfile.resolution, forKey: "scrcpy_active_resolution")
        UserDefaults.standard.set(activeProfile.bitrateMbps, forKey: "scrcpy_active_bitrate")
        UserDefaults.standard.set(activeProfile.fps, forKey: "scrcpy_active_fps")
        UserDefaults.standard.set(activeProfile.audioEnabled, forKey: "scrcpy_active_audio")
        UserDefaults.standard.set(activeProfile.cameraFacing.rawValue, forKey: "scrcpy_active_camera_facing")
        UserDefaults.standard.set(activeProfile.stayAwake, forKey: "scrcpy_active_stay_awake")
        UserDefaults.standard.set(activeProfile.showTouches, forKey: "scrcpy_active_show_touches")
        UserDefaults.standard.set(activeProfile.customServerArgs, forKey: "scrcpy_active_custom_args")

        UserDefaults.standard.synchronize()
    }

    public func createNewProfile(name: String, host: String, port: UInt16 = 5555) -> ConnectionProfile {
        let newProfile = ConnectionProfile(
            name: name.isEmpty ? "New Device" : name,
            host: host.isEmpty ? "192.168.1.100" : host,
            port: port,
            resolution: activeProfile.resolution,
            bitrateMbps: activeProfile.bitrateMbps,
            fps: activeProfile.fps,
            codec: activeProfile.codec,
            audioEnabled: activeProfile.audioEnabled,
            stayAwake: activeProfile.stayAwake,
            showTouches: activeProfile.showTouches
        )
        profiles.append(newProfile)
        activeProfile = newProfile
        saveCurrentState()
        return newProfile
    }

    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].name = trimmed
            if activeProfile.id == id {
                activeProfile.name = trimmed
            }
            saveCurrentState()
        }
    }

    public func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return } // Keep at least one profile
        profiles.removeAll(where: { $0.id == id })
        if activeProfile.id == id, let first = profiles.first {
            activeProfile = first
        }
        saveCurrentState()
    }

    /// Records a successful connection to a device, updating lastConnected and device name
    public func recordSuccessfulConnection(host: String, port: UInt16, deviceName: String?) {
        var targetIndex: Int? = profiles.firstIndex(where: { $0.host == host && $0.port == port })
        if targetIndex == nil {
            targetIndex = profiles.firstIndex(where: { $0.id == activeProfile.id })
        }

        if let idx = targetIndex {
            profiles[idx].lastConnected = Date()
            if let name = deviceName, !name.isEmpty,
               profiles[idx].name == "Android Device" || profiles[idx].name == "New Device" {
                profiles[idx].name = name
            }
            if activeProfile.id == profiles[idx].id {
                activeProfile = profiles[idx]
            }
            saveCurrentState()
        }
    }
}
