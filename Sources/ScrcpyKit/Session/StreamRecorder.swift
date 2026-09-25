import Foundation
import AVFoundation
import CoreMedia
#if canImport(Photos)
import Photos
#endif

/// High-efficiency zero-transcode MP4 stream recorder for Scrcpy video and audio streams.
/// Directly muxes incoming H.264/H.265 NALUs into an MP4 container without re-encoding,
/// ensuring 0% extra CPU/GPU usage and lossless recording quality.
public final class StreamRecorder: ObservableObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case waitingForFirstKeyframe
        case recording(startTime: Date, fileURL: URL)
        case finishing
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecordedURL: URL?

    private let lock = NSLock()
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var targetURL: URL?
    private var isAudioIncluded: Bool = false
    private var firstVideoPts: CMTime = .invalid
    private var lastVideoPts: CMTime = .invalid
    private var lastAudioPts: CMTime = .invalid
    private var timerTask: Task<Void, Never>?

    // Audio format description cache
    private var audioFormatDescription: CMAudioFormatDescription?

    public init() {
        _ = Self.recordingsDirectory
    }

    deinit {
        timerTask?.cancel()
    }

    /// The app's shared recordings directory, accessible in the iOS Files app
    public static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Prepares and arms the recorder to capture incoming frames.
    /// Actual file writing begins as soon as the first IDR/Keyframe is received.
    public func startRecording(
        source: ScrcpyVideoSource = .camera,
        includeAudio: Bool = true,
        customFileName: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard state == .idle else { return }

        _ = Self.recordingsDirectory

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let sourcePrefix = (source == .camera) ? "Camera" : "Screen"
        let filename = customFileName ?? "Scrcpy_\(sourcePrefix)_\(timestamp).mp4"
        let outputURL = Self.recordingsDirectory.appendingPathComponent(filename)

        // Remove previous file if exists
        try? FileManager.default.removeItem(at: outputURL)

        self.targetURL = outputURL
        self.isAudioIncluded = includeAudio
        self.firstVideoPts = .invalid
        self.lastVideoPts = .invalid
        self.lastAudioPts = .invalid
        self.state = .waitingForFirstKeyframe

        Task { @MainActor in
            self.isRecording = true
            self.recordingDuration = 0
        }

        print("[StreamRecorder] Armed and waiting for first keyframe -> \(outputURL.lastPathComponent)")
    }

    /// Appends an incoming pre-compressed video sample buffer directly into the MP4 file.
    public func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .waitingForFirstKeyframe:
            guard isKeyframe(sampleBuffer) else {
                return
            }

            guard let url = targetURL,
                  let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }

            do {
                let writer = try AVAssetWriter(url: url, fileType: .mp4)
                let vInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: nil,
                    sourceFormatHint: formatDesc
                )
                vInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(vInput) else {
                    print("[StreamRecorder] Error: Cannot add video input to asset writer")
                    self.state = .idle
                    Task { @MainActor in self.isRecording = false }
                    return
                }
                writer.add(vInput)

                if isAudioIncluded {
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: 2,
                        AVSampleRateKey: 48000.0,
                        AVEncoderBitRateKey: 128_000
                    ]
                    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    aInput.expectsMediaDataInRealTime = true
                    if writer.canAdd(aInput) {
                        writer.add(aInput)
                        self.audioInput = aInput
                    }
                }

                guard writer.startWriting() else {
                    print("[StreamRecorder] Error starting writer: \(String(describing: writer.error))")
                    self.state = .idle
                    Task { @MainActor in self.isRecording = false }
                    return
                }

                let pts = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: .zero)
                self.firstVideoPts = pts
                self.lastVideoPts = .zero
                self.lastAudioPts = .invalid
                self.assetWriter = writer
                self.videoInput = vInput

                // Re-time initial keyframe to .zero
                var timingInfo = CMSampleTimingInfo(
                    duration: sampleBuffer.duration.isValid ? sampleBuffer.duration : CMTime.invalid,
                    presentationTimeStamp: .zero,
                    decodeTimeStamp: .invalid
                )
                var reTimedBuffer: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sampleBuffer,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timingInfo,
                    sampleBufferOut: &reTimedBuffer
                )

                if status == noErr, let buffer = reTimedBuffer, vInput.isReadyForMoreMediaData {
                    vInput.append(buffer)
                }

                let startDate = Date()
                self.state = .recording(startTime: startDate, fileURL: url)

                // Start duration timer
                startDurationTimer(startDate: startDate)

                print("[StreamRecorder] Recording started with initial keyframe (source PTS: \(pts.seconds)s -> normalized to 0.0s)")
            } catch {
                print("[StreamRecorder] Failed to create AVAssetWriter: \(error)")
                self.state = .idle
                Task { @MainActor in self.isRecording = false }
            }

        case .recording:
            guard let vInput = videoInput, vInput.isReadyForMoreMediaData else { return }
            guard firstVideoPts.isValid else { return }

            let rawRelPts = CMTimeSubtract(sampleBuffer.presentationTimeStamp, firstVideoPts)
            var relPts = (rawRelPts < .zero) ? .zero : rawRelPts

            if lastVideoPts.isValid && relPts <= lastVideoPts {
                relPts = CMTimeAdd(lastVideoPts, CMTime(value: 1, timescale: 1000))
            }
            lastVideoPts = relPts

            var timingInfo = CMSampleTimingInfo(
                duration: sampleBuffer.duration.isValid ? sampleBuffer.duration : CMTime.invalid,
                presentationTimeStamp: relPts,
                decodeTimeStamp: .invalid
            )
            var reTimedBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &reTimedBuffer
            )

            if status == noErr, let buffer = reTimedBuffer {
                vInput.append(buffer)
            }

        case .idle, .finishing:
            break
        }
    }

    /// Appends incoming 48kHz stereo 16-bit PCM audio data.
    public func appendAudioData(_ pcmData: Data, pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        guard case .recording = state,
              let aInput = audioInput,
              aInput.isReadyForMoreMediaData else {
            return
        }

        guard firstVideoPts.isValid else { return }

        let frameCount = pcmData.count / 4
        guard frameCount > 0 else { return }

        let rawRelPts = CMTimeSubtract(pts, firstVideoPts)
        // Drop any audio packets that occurred before the first video keyframe
        if rawRelPts < .zero {
            return
        }

        var relPts = rawRelPts
        if lastAudioPts.isValid && relPts <= lastAudioPts {
            relPts = CMTimeAdd(lastAudioPts, CMTime(value: CMTimeValue(frameCount), timescale: 48000))
        }
        lastAudioPts = relPts

        guard let sampleBuffer = createAudioSampleBuffer(pcmData: pcmData, pts: relPts, frameCount: frameCount) else {
            return
        }

        aInput.append(sampleBuffer)
    }

    /// Stops the recording session, finishes muxing the MP4 container, and returns the recorded file URL.
    @discardableResult
    public func stopRecording() async throws -> URL? {
        timerTask?.cancel()
        timerTask = nil

        let (writer, vInput, aInput, fileURL) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, URL?) in
            guard state != .idle else { return (nil, nil, nil, nil) }
            let url = targetURL
            let w = assetWriter
            let v = videoInput
            let a = audioInput

            self.state = .finishing
            return (w, v, a, url)
        }

        defer {
            lock.withLock {
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.targetURL = nil
                self.firstVideoPts = .invalid
                self.lastVideoPts = .invalid
                self.lastAudioPts = .invalid
                self.audioFormatDescription = nil
                self.state = .idle
            }
            Task { @MainActor in
                self.isRecording = false
                self.recordingDuration = 0
            }
        }

        guard let writer = writer else {
            print("[StreamRecorder] Recording cancelled before any keyframe was received.")
            return nil
        }

        vInput?.markAsFinished()
        aInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if let error = writer.error {
            print("[StreamRecorder] Error finishing MP4 writing: \(error)")
            throw error
        }

        print("[StreamRecorder] Successfully recorded MP4: \(fileURL?.path ?? "")")
        if let url = fileURL {
            Task { @MainActor in
                self.lastRecordedURL = url
            }
        }
        return fileURL
    }

    private func startDurationTimer(startDate: Date) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self else { break }
                let elapsed = Date().timeIntervalSince(startDate)
                await MainActor.run {
                    self.recordingDuration = elapsed
                }
            }
        }
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
              let first = attachments.first else {
            return true
        }

        if let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }
        return true
    }

    private func createAudioSampleBuffer(pcmData: Data, pts: CMTime, frameCount: Int) -> CMSampleBuffer? {
        if audioFormatDescription == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48000.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var formatDesc: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
            if status == noErr {
                self.audioFormatDescription = formatDesc
            }
        }

        guard let format = audioFormatDescription else { return nil }
        guard frameCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: pcmData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: pcmData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        pcmData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            _ = CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcmData.count)
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }

    #if canImport(Photos)
    /// Saves a video file at URL directly to the user's Photos library (Camera Roll)
    public static func saveToPhotos(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "ScrcpyRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Photo library access was not granted by the user."]
            )
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }
    #endif
}
