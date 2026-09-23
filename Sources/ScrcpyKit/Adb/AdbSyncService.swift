import Foundation

public enum AdbSyncError: Error, LocalizedError {
    case sendFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): return "ADB sync push failed: \(msg)"
        case .invalidResponse: return "ADB sync received invalid response."
        }
    }
}

/// Implements the ADB sync: protocol to push files to Android devices
public final class AdbSyncService: Sendable {
    private let connection: AdbConnection

    public init(connection: AdbConnection) {
        self.connection = connection
    }

    /// Push local data to a remote path on the Android filesystem (e.g. /data/local/tmp/scrcpy-server.jar)
    public func pushFile(data: Data, remotePath: String, mode: UInt32 = 0o644) async throws {
        let stream = try await connection.openStream(destination: "sync:")

        // Step 1: Send SEND header
        // Path specification format: "<path>,<mode>"
        let pathSpec = "\(remotePath),\(mode)"
        guard let pathBytes = pathSpec.data(using: .utf8) else {
            throw AdbSyncError.sendFailed("Invalid path specification")
        }

        var sendHeader = Data()
        sendHeader.append("SEND".data(using: .utf8)!)
        sendHeader.appendLittleEndian(UInt32(pathBytes.count))
        sendHeader.append(pathBytes)

        try await stream.write(sendHeader)

        // Step 2: Send DATA chunks
        let chunkSize = 64 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)

            var chunkHeader = Data()
            chunkHeader.append("DATA".data(using: .utf8)!)
            chunkHeader.appendLittleEndian(UInt32(chunk.count))
            chunkHeader.append(chunk)

            try await stream.write(chunkHeader)
            offset = end
        }

        // Step 3: Send DONE
        var doneHeader = Data()
        doneHeader.append("DONE".data(using: .utf8)!)
        doneHeader.appendLittleEndian(UInt32(Date().timeIntervalSince1970))
        try await stream.write(doneHeader)

        // Step 4: Read response (OKAY or FAIL)
        var responseBuffer = Data()
        for await chunk in stream.incomingData {
            responseBuffer.append(chunk)
            if responseBuffer.count >= 8 {
                break
            }
        }

        guard responseBuffer.count >= 4 else {
            throw AdbSyncError.invalidResponse
        }

        let status = String(data: responseBuffer.subdata(in: 0..<4), encoding: .utf8)
        if status == "FAIL" {
            var msg = "Unknown sync error"
            if responseBuffer.count >= 8 {
                let msgLen = Int(responseBuffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian })
                if responseBuffer.count >= 8 + msgLen {
                    msg = String(data: responseBuffer.subdata(in: 8..<(8 + msgLen)), encoding: .utf8) ?? msg
                }
            }
            throw AdbSyncError.sendFailed(msg)
        } else if status != "OKAY" {
            throw AdbSyncError.invalidResponse
        }

        // Step 5: Send QUIT
        var quitHeader = Data()
        quitHeader.append("QUIT".data(using: .utf8)!)
        quitHeader.append(value: UInt32(0))
        try? await stream.write(quitHeader)
        await stream.close()
    }
}
