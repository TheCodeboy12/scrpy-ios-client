import Foundation
import Darwin

public enum AdbPairResult: Sendable {
    case success(String)
    case failure(String)
}

public final class AdbPairService: Sendable {
    public init() {}

    /// Performs wireless pairing using system ADB CLI if available (macOS & iOS Simulator)
    public static func pair(host: String, port: UInt16, code: String) async -> AdbPairResult {
        let adbPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ]

        var foundAdb: String?
        for path in adbPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                foundAdb = path
                break
            }
        }

        guard let adb = foundAdb else {
            return .failure("Standalone physical iOS devices cannot run SPAKE2 pairing directly. Please connect your Android device using standard port 5555 (via 'adb tcpip 5555'), or pair once with any computer on your Wi-Fi network.")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = "\(host):\(port)"
                let result = runSpawn(
                    executable: adb,
                    arguments: ["pair", target, code]
                )

                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 0 || output.lowercased().contains("successfully paired") {
                    continuation.resume(returning: .success(output.isEmpty ? "Successfully paired to \(target)" : output))
                } else {
                    let errMsg = output.isEmpty ? "Pairing failed with exit code \(result.status)" : output
                    continuation.resume(returning: .failure(errMsg))
                }
            }
        }
    }

    private static func runSpawn(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        var pipeOut: [Int32] = [0, 0]
        guard pipe(&pipeOut) == 0 else {
            return (-1, "Pipe creation failed")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeOut[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeOut[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeOut[0])

        let allArgs = [executable] + arguments
        let cArgs = allArgs.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgs {
                if let p = ptr { free(p) }
            }
        }

        // Resolve user's actual home directory on Mac (even from simulator sandbox)
        var homeDir = NSHomeDirectory()
        let parts = homeDir.components(separatedBy: "/")
        if parts.count >= 3, parts[1] == "Users" {
            let hostUserHome = "/Users/\(parts[2])"
            if FileManager.default.fileExists(atPath: hostUserHome) {
                homeDir = hostUserHome
            }
        }

        let envStrings = [
            "HOME=\(homeDir)",
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cEnv {
                if let p = ptr { free(p) }
            }
        }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &fileActions, nil, cArgs, cEnv)
        posix_spawn_file_actions_destroy(&fileActions)
        close(pipeOut[1])

        if spawnStatus != 0 {
            close(pipeOut[0])
            return (spawnStatus, "Failed to launch ADB process (code: \(spawnStatus))")
        }

        let fileHandle = FileHandle(fileDescriptor: pipeOut[0], closeOnDealloc: true)
        let outputData = fileHandle.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        var waitStatus: Int32 = 0
        waitpid(pid, &waitStatus, 0)
        let exitCode = (waitStatus >> 8) & 0xff
        return (exitCode, output)
    }
}
