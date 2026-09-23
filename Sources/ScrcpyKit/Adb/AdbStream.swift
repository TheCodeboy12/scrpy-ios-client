import Foundation

/// Represents a single multiplexed channel/stream over an ADB connection.
public final class AdbStream: @unchecked Sendable {
    public let localId: UInt32
    public internal(set) var remoteId: UInt32 = 0
    public internal(set) var isOpen: Bool = false

    private weak var connection: AdbConnection?
    private let continuation: AsyncStream<Data>.Continuation
    public let incomingData: AsyncStream<Data>

    private var writeContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(localId: UInt32, connection: AdbConnection) {
        self.localId = localId
        self.connection = connection

        var cont: AsyncStream<Data>.Continuation!
        self.incomingData = AsyncStream<Data> { c in
            cont = c
        }
        self.continuation = cont
    }

    /// Called by AdbConnection when WRTE data arrives for this stream
    func receiveData(_ data: Data) {
        continuation.yield(data)
    }

    /// Called when the device sends OKAY for our pending write or stream open
    func handleOkay(remoteId: UInt32) {
        lock.lock()
        self.remoteId = remoteId
        self.isOpen = true
        let continuation = writeContinuation
        writeContinuation = nil
        lock.unlock()

        continuation?.resume()
    }

    /// Called when the remote closes the stream
    func handleClose() {
        lock.lock()
        isOpen = false
        let continuation = writeContinuation
        writeContinuation = nil
        lock.unlock()

        continuation?.resume(throwing: AdbError.streamClosed)
        self.continuation.finish()
    }

    /// Send data through this stream and wait for OKAY acknowledgment
    public func write(_ data: Data) async throws {
        guard isOpen, let conn = connection else {
            throw AdbError.streamClosed
        }

        // Split data into chunks if larger than max payload
        var offset = 0
        let chunkSize = 64 * 1024 // 64 KB per chunk
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.writeContinuation = continuation
                lock.unlock()

                Task {
                    do {
                        try await conn.sendWrite(localId: self.localId, remoteId: self.remoteId, data: chunk)
                    } catch {
                        self.lock.withLock {
                            self.writeContinuation = nil
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
            offset = end
        }
    }

    /// Close this stream
    public func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard isOpen else { return false }
            isOpen = false
            return true
        }
        guard shouldClose, let conn = connection else { return }

        await conn.sendClose(localId: localId, remoteId: remoteId)
        continuation.finish()
    }
}
