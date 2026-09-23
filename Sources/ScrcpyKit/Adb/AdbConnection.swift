import Foundation
import Network

public enum AdbError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed
    case streamClosed
    case handshakeFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "ADB connection failed: \(msg)"
        case .authenticationFailed: return "ADB authorization failed or was rejected on the device."
        case .streamClosed: return "ADB stream was closed."
        case .handshakeFailed: return "ADB handshake failed."
        case .timeout: return "ADB connection timed out."
        }
    }
}

/// Pure Swift ADB connection over TCP via Network.framework
public final class AdbConnection: @unchecked Sendable {
    public let host: String
    public let port: UInt16

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.scrcpy.adb.connection", qos: .userInitiated)

    private struct PendingOpen {
        let continuation: CheckedContinuation<AdbStream, Error>
        let timer: DispatchSourceTimer?
    }
    private var nextLocalId: UInt32 = 1
    private var streams = [UInt32: AdbStream]()
    private var pendingOpens = [UInt32: PendingOpen]()
    private let lock = NSLock()

    private var isConnected = false
    public private(set) var deviceBanner: String = ""

    public init(host: String, port: UInt16 = 5555) {
        self.host = host
        self.port = port
    }

    public var onHandshakeStep: (@Sendable (String) -> Void)?

    /// Establish connection and perform ADB authentication handshake
    public func connect(timeoutSeconds: TimeInterval = 10) async throws {
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw AdbError.connectionFailed("Invalid port \(port)")
        }

        let nwConn = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        self.connection = nwConn

        final class ResumeGate: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            func resumeOnce(continuation: CheckedContinuation<Void, Error>, result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success: continuation.resume()
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
        }
        let gate = ResumeGate()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                gate.resumeOnce(continuation: continuation, result: .failure(AdbError.connectionFailed("Connection timed out after \(Int(timeoutSeconds))s. Please verify the IP and Port.")))
                nwConn.cancel()
            }
            timer.resume()

            nwConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timer.cancel()
                    gate.resumeOnce(continuation: continuation, result: .success(()))
                case .failed(let err):
                    timer.cancel()
                    gate.resumeOnce(continuation: continuation, result: .failure(AdbError.connectionFailed(err.localizedDescription)))
                case .cancelled:
                    timer.cancel()
                    gate.resumeOnce(continuation: continuation, result: .failure(AdbError.connectionFailed("Connection cancelled")))
                default:
                    break
                }
            }
            nwConn.start(queue: self.queue)
        }

        // Perform ADB Handshake
        try await performHandshake()
        self.isConnected = true

        // Start background message receiving loop
        startReceiveLoop()
    }

    private func performHandshake() async throws {
        // Step 1: Send CNXN
        let identity = "host::features=cmd,shell_v2,stat_v2,ls_v2\0"
        let identityData = identity.data(using: .utf8)!
        let cnxnMsg = AdbMessage(command: .cnxn, arg0: 0x01000000, arg1: AdbMessage.maxPayloadSize, payload: identityData)
        try await sendRawMessage(cnxnMsg)

        // Step 2: Read initial response
        let resp = try await readSingleMessage()
        if resp.command == .cnxn {
            self.deviceBanner = String(data: resp.payload, encoding: .utf8) ?? ""
            return
        }

        guard resp.command == .auth, resp.arg0 == 1 else { // AUTH_TYPE_TOKEN
            throw AdbError.handshakeFailed
        }

        let token = resp.payload

        // Step 3: Try signing token with existing RSA private key
        if let signature = AdbCrypto.shared.sign(token: token) {
            let authMsg = AdbMessage(command: .auth, arg0: 2, arg1: 0, payload: signature) // AUTH_TYPE_SIGNATURE
            try await sendRawMessage(authMsg)

            let authResp = try await readSingleMessage()
            if authResp.command == .cnxn {
                self.deviceBanner = String(data: authResp.payload, encoding: .utf8) ?? ""
                return
            }
        }

        // Step 4: Signature rejected or first time; send Public Key for device prompt
        onHandshakeStep?("Waiting for authorization... Please tap 'Allow' on your Android screen!")
        let pubKeyPayload = AdbCrypto.shared.getAdbPublicKeyPayload()
        let pubKeyMsg = AdbMessage(command: .auth, arg0: 3, arg1: 0, payload: pubKeyPayload) // AUTH_TYPE_RSA_PUBLIC_KEY
        try await sendRawMessage(pubKeyMsg)

        // Wait for device prompt acceptance (may take some time while user confirms)
        let finalResp = try await readSingleMessage()
        guard finalResp.command == .cnxn else {
            throw AdbError.authenticationFailed
        }
        self.deviceBanner = String(data: finalResp.payload, encoding: .utf8) ?? ""
    }

    /// Open a new channel to a destination service (e.g. "shell:...", "sync:", "localabstract:scrcpy_...")
    public func openStream(destination: String) async throws -> AdbStream {
        guard isConnected else { throw AdbError.connectionFailed("Not connected") }

        let localId: UInt32 = lock.withLock {
            let id = nextLocalId
            nextLocalId &+= 1
            return id
        }

        let stream = AdbStream(localId: localId, connection: self)
        lock.withLock {
            streams[localId] = stream
        }

        var destData = destination.data(using: .utf8)!
        destData.append(0) // null-terminated

        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 6.0)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                var pending: PendingOpen?
                self.lock.withLock {
                    pending = self.pendingOpens.removeValue(forKey: localId)
                    _ = self.streams.removeValue(forKey: localId)
                }
                pending?.continuation.resume(throwing: AdbError.connectionFailed("Stream open timed out for \(destination)"))
            }
            timer.resume()

            lock.withLock {
                pendingOpens[localId] = PendingOpen(continuation: continuation, timer: timer)
            }

            let openMsg = AdbMessage(command: .open, arg0: localId, arg1: 0, payload: destData)
            Task {
                do {
                    try await self.sendRawMessage(openMsg)
                } catch {
                    timer.cancel()
                    self.lock.withLock {
                        _ = self.pendingOpens.removeValue(forKey: localId)
                        _ = self.streams.removeValue(forKey: localId)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendWrite(localId: UInt32, remoteId: UInt32, data: Data) async throws {
        let msg = AdbMessage(command: .wrte, arg0: localId, arg1: remoteId, payload: data)
        try await sendRawMessage(msg)
    }

    func sendClose(localId: UInt32, remoteId: UInt32) async {
        let msg = AdbMessage(command: .clse, arg0: localId, arg1: remoteId)
        try? await sendRawMessage(msg)
        lock.withLock {
            _ = streams.removeValue(forKey: localId)
        }
    }

    private func sendRawMessage(_ msg: AdbMessage) async throws {
        guard let conn = connection else { throw AdbError.streamClosed }
        let data = msg.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readExact(length: Int) async throws -> Data {
        guard let conn = connection else { throw AdbError.streamClosed }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count == length {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: AdbError.streamClosed)
                } else {
                    continuation.resume(throwing: AdbError.connectionFailed("Incomplete read"))
                }
            }
        }
    }

    private func readSingleMessage() async throws -> AdbMessage {
        let headerData = try await readExact(length: AdbMessage.headerSize)
        guard let msg = AdbMessage(headerData: headerData) else {
            throw AdbError.handshakeFailed
        }

        if msg.dataLength > 0 {
            let payload = try await readExact(length: Int(msg.dataLength))
            return AdbMessage(headerData: headerData, payload: payload) ?? msg
        }
        return msg
    }

    private func startReceiveLoop() {
        Task { [weak self] in
            while let self = self, self.isConnected {
                do {
                    let msg = try await self.readSingleMessage()
                    await self.handleIncomingMessage(msg)
                } catch {
                    self.disconnect()
                    break
                }
            }
        }
    }

    private func handleIncomingMessage(_ msg: AdbMessage) async {
        switch msg.command {
        case .okay:
            let localId = msg.arg1
            let remoteId = msg.arg0

            var pending: PendingOpen?
            var stream: AdbStream?

            lock.withLock {
                pending = pendingOpens.removeValue(forKey: localId)
                stream = streams[localId]
            }

            pending?.timer?.cancel()
            if let continuation = pending?.continuation, let stream = stream {
                stream.handleOkay(remoteId: remoteId)
                continuation.resume(returning: stream)
            } else if let stream = stream {
                stream.handleOkay(remoteId: remoteId)
            }

        case .wrte:
            let localId = msg.arg1
            let remoteId = msg.arg0
            let stream = lock.withLock { streams[localId] }

            if let stream = stream {
                stream.receiveData(msg.payload)
                // Acknowledge incoming packet with OKAY
                let ack = AdbMessage(command: .okay, arg0: localId, arg1: remoteId)
                try? await sendRawMessage(ack)
            }

        case .clse:
            let localId = msg.arg1
            var pending: PendingOpen?
            var stream: AdbStream?

            lock.withLock {
                pending = pendingOpens.removeValue(forKey: localId)
                stream = streams.removeValue(forKey: localId)
            }

            pending?.timer?.cancel()
            if let continuation = pending?.continuation {
                continuation.resume(throwing: AdbError.connectionFailed("Stream rejected by device (closed)"))
            }
            stream?.handleClose()

        default:
            break
        }
    }

    public func disconnect() {
        isConnected = false
        connection?.cancel()
        connection = nil

        lock.withLock {
            for (_, pending) in pendingOpens {
                pending.timer?.cancel()
                pending.continuation.resume(throwing: AdbError.streamClosed)
            }
            pendingOpens.removeAll()

            for (_, stream) in streams {
                stream.handleClose()
            }
            streams.removeAll()
        }
    }
}
