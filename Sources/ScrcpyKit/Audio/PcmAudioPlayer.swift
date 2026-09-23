import Foundation
import AVFoundation

/// Low-latency PCM Audio Player for Scrcpy audio streaming (48kHz, 2-channel stereo, 16-bit LE)
public final class PcmAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false
    private let lock = NSLock()

    // Circular sample buffer for Int16 samples (stereo interleaved)
    // 48000 Hz * 2 channels = 96000 samples/sec (192,000 bytes/sec)
    // 65536 samples capacity = ~680ms max buffer to absorb network jitter
    private let capacity: Int = 65536
    private var buffer: [Int16]
    private var readPos: Int = 0
    private var writePos: Int = 0
    private var availableSamples: Int = 0

    public init() {
        self.buffer = [Int16](repeating: 0, count: capacity)
        setupAudioSession()
        setupEngine()
    }

    deinit {
        stop()
    }

    private func setupAudioSession() {
        #if canImport(UIKit) && !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("[PcmAudioPlayer] Failed to set AVAudioSession category: \(error)")
        }
        #endif
    }

    private func setupEngine() {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            print("[PcmAudioPlayer] Could not create AVAudioFormat")
            return
        }

        // Render block called by CoreAudio real-time thread
        let node = AVAudioSourceNode { [weak self] isSilence, timestamp, frameCount, outputData -> OSStatus in
            guard let self = self else {
                isSilence.pointee = true
                return noErr
            }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                return noErr
            }

            let frames = Int(frameCount)
            let samplesNeeded = frames * 2

            self.lock.lock()
            let available = self.availableSamples
            let toRead = min(available, samplesNeeded)

            var frameIdx = 0
            while frameIdx < (toRead / 2) {
                let leftInt = self.buffer[self.readPos]
                let rightInt = self.buffer[(self.readPos + 1) % self.capacity]
                self.readPos = (self.readPos + 2) % self.capacity

                leftPtr[frameIdx] = Float(leftInt) / 32768.0
                rightPtr[frameIdx] = Float(rightInt) / 32768.0
                frameIdx += 1
            }

            self.availableSamples -= toRead
            self.lock.unlock()

            // If we didn't have enough samples, fill remainder with silence
            if frameIdx < frames {
                for i in frameIdx..<frames {
                    leftPtr[i] = 0.0
                    rightPtr[i] = 0.0
                }
            }

            isSilence.pointee = ObjCBool(toRead == 0)
            return noErr
        }

        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
    }

    public func start() {
        guard !isRunning else { return }
        setupAudioSession()

        do {
            try engine.start()
            isRunning = true
            print("[PcmAudioPlayer] Audio engine started successfully (48kHz Stereo)")
        } catch {
            print("[PcmAudioPlayer] Failed to start audio engine: \(error)")
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false

        lock.lock()
        readPos = 0
        writePos = 0
        availableSamples = 0
        lock.unlock()
        print("[PcmAudioPlayer] Audio engine stopped")
    }

    /// Enqueue raw Little-Endian 16-bit stereo PCM data from Scrcpy server
    public func enqueue(data: Data) {
        guard !data.isEmpty else { return }
        if !isRunning {
            start()
        }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        data.withUnsafeBytes { rawBuffer in
            guard let int16Buffer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }

            for i in 0..<sampleCount {
                // Little-endian to host byte order
                let sample = Int16(littleEndian: int16Buffer[i])
                buffer[writePos] = sample
                writePos = (writePos + 1) % capacity

                if availableSamples < capacity {
                    availableSamples += 1
                } else {
                    // Buffer overrun: advance read pointer to discard oldest sample
                    readPos = (readPos + 1) % capacity
                }
            }
        }
    }
}
