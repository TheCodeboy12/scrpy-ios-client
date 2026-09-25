import Foundation
import AVFoundation
import CoreMedia
import ScrcpyKit

func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        print("❌ Assertion Failed at \(file):\(line): \(message)")
        exit(1)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        print("❌ Assertion Failed at \(file):\(line): Expected '\(b)', got '\(a)' - \(message)")
        exit(1)
    }
}

print("========================================")
print("  Running ScrcpyKit Automated Test Suite")
print("========================================")

// MARK: - AdbMessage Tests
print("[TEST] AdbMessage Tests...")
do {
    let payload = "host::features=cmd,shell_v2\0".data(using: .utf8)!
    let msg = AdbMessage(command: .cnxn, arg0: 0x01000000, arg1: 256 * 1024, payload: payload)

    let serialized = msg.serialize()
    assertEqual(serialized.count, AdbMessage.headerSize + payload.count, "Serialized size")

    let parsed = AdbMessage(headerData: serialized.subdata(in: 0..<AdbMessage.headerSize), payload: payload)
    assertTrue(parsed != nil, "Parsing valid message")
    assertEqual(parsed?.command, .cnxn, "Command match")
    assertEqual(parsed?.arg0, 0x01000000, "arg0 match")
    assertEqual(parsed?.arg1, 256 * 1024, "arg1 match")
    assertEqual(parsed?.dataLength, UInt32(payload.count), "payload count match")
    assertEqual(parsed?.magic, AdbCommand.cnxn.rawValue ^ 0xFFFFFFFF, "magic match")
    assertEqual(parsed?.payload, payload, "payload content match")

    let testData = Data([0x01, 0x02, 0x03, 0x04])
    assertEqual(AdbMessage.checksum(for: testData), 10, "Checksum calculation")
    print("  ✓ AdbMessage tests passed")
}

// MARK: - AdbCrypto Tests
print("[TEST] AdbCrypto RSA & Android Public Key Tests...")
do {
    let crypto = AdbCrypto()
    let fakeToken = Data(repeating: 0x42, count: 20)
    let sig = crypto.sign(token: fakeToken)
    assertTrue(sig != nil, "RSA token signing")
    assertEqual(sig?.count, 256, "RSA-2048 signature size (256 bytes)")

    let pubPayload = crypto.getAdbPublicKeyPayload()
    guard let pubStr = String(data: pubPayload, encoding: .utf8)?
        .trimmingCharacters(in: .controlCharacters) else {
        fatalError("Failed to decode pubKey")
    }

    let parts = pubStr.split(separator: " ")
    assertTrue(parts.count >= 2, "PublicKey format must have base64 and tag")
    assertEqual(parts.last, "scrcpy@ios", "Tag match")

    guard let binaryData = Data(base64Encoded: String(parts[0])) else {
        fatalError("Base64 decoding failed")
    }

    // RSAPublicKey binary struct is exactly 524 bytes
    assertEqual(binaryData.count, 524, "RSAPublicKey struct size")
    let words = binaryData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    assertEqual(words, 64, "Modulus size in words must be 64 (2048 / 32)")
    print("  ✓ AdbCrypto tests passed")
}

// MARK: - ScrcpyProtocol Tests
print("[TEST] ScrcpyProtocol Packet & Control Tests...")
do {
    // Session Packet
    var sessData = Data()
    var flags = UInt32(0x80000001).bigEndian
    var width = UInt32(1080).bigEndian
    var height = UInt32(2400).bigEndian
    Swift.withUnsafeBytes(of: &flags) { sessData.append(contentsOf: $0) }
    Swift.withUnsafeBytes(of: &width) { sessData.append(contentsOf: $0) }
    Swift.withUnsafeBytes(of: &height) { sessData.append(contentsOf: $0) }

    let session = ScrcpySessionMeta(data: sessData)
    assertTrue(session != nil, "Session packet parsing")
    assertEqual(session?.width, 1080, "Width")
    assertEqual(session?.height, 2400, "Height")
    assertEqual(session?.isClientResize, true, "Client resize")

    // Media Packet Header
    var mediaData = Data()
    var ptsFlags = UInt64(0x2000000000000000 | 9876543).bigEndian
    var pSize = UInt32(8192).bigEndian
    Swift.withUnsafeBytes(of: &ptsFlags) { mediaData.append(contentsOf: $0) }
    Swift.withUnsafeBytes(of: &pSize) { mediaData.append(contentsOf: $0) }

    let media = ScrcpyMediaPacketHeader(data: mediaData)
    assertTrue(media != nil, "Media packet parsing")
    assertEqual(media?.pts, 9876543, "PTS")
    assertEqual(media?.isKeyFrame, true, "isKeyFrame")
    assertEqual(media?.isConfig, false, "isConfig")
    assertEqual(media?.packetSize, 8192, "packetSize")

    // Touch Event Serialization
    let touch = ScrcpyControlMessage.injectTouchEvent(
        action: .down,
        pointerId: 0,
        x: 540,
        y: 1200,
        screenWidth: 1080,
        screenHeight: 2400,
        pressure: 1.0
    )
    let touchData = touch.serialize()
    assertEqual(touchData.count, 32, "Touch message size")
    assertEqual(touchData[0], 2, "Type inject touch")
    assertEqual(touchData[1], 0, "Action down")

    let posX = touchData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Int32.self).bigEndian }
    let posY = touchData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: Int32.self).bigEndian }
    let sw = touchData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 18, as: UInt16.self).bigEndian }
    let sh = touchData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt16.self).bigEndian }
    let pressure = touchData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self).bigEndian }

    assertEqual(posX, 540, "X position")
    assertEqual(posY, 1200, "Y position")
    assertEqual(sw, 1080, "Screen width")
    assertEqual(sh, 2400, "Screen height")
    assertEqual(pressure, 0xFFFF, "Max pressure 0xFFFF")

    // Keycode Serialization
    let keycodeMsg = ScrcpyControlMessage.injectKeycode(action: .down, keycode: .home)
    let keycodeData = keycodeMsg.serialize()
    assertEqual(keycodeData.count, 14, "Keycode message size")
    assertEqual(keycodeData[0], 0, "Type inject keycode")
    let kc = keycodeData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt32.self).bigEndian }
    assertEqual(kc, AndroidKeycode.home.rawValue, "Keycode home")

    // Text Injection
    let text = "ScrcpyKit on iOS"
    let textMsg = ScrcpyControlMessage.injectText(text)
    let textData = textMsg.serialize()
    assertEqual(textData[0], 1, "Type inject text")
    let textLen = textData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian }
    assertEqual(textLen, UInt32(text.utf8.count), "Text length")
    let decodedText = String(data: textData.subdata(in: 5..<(5 + Int(textLen))), encoding: .utf8)
    assertEqual(decodedText, text, "Text payload match")

    // Camera Control Messages
    let torchOn = ScrcpyControlMessage.cameraSetTorch(true).serialize()
    assertEqual(torchOn.count, 2, "Torch message size")
    assertEqual(torchOn[0], 18, "Torch type 18")
    assertEqual(torchOn[1], 1, "Torch on")

    let zoomIn = ScrcpyControlMessage.cameraZoomIn.serialize()
    assertEqual(zoomIn.count, 1, "Zoom in size")
    assertEqual(zoomIn[0], 19, "Zoom in type 19")

    let zoomOut = ScrcpyControlMessage.cameraZoomOut.serialize()
    assertEqual(zoomOut.count, 1, "Zoom out size")
    assertEqual(zoomOut[0], 20, "Zoom out type 20")

    // Device Clipboard Message Deserialization
    var clipData = Data()
    clipData.append(0) // DEVICE_MSG_TYPE_CLIPBOARD
    let clipStr = "Test clipboard payload"
    clipData.appendBigEndian(UInt32(clipStr.utf8.count))
    clipData.append(clipStr.data(using: .utf8)!)

    let clipResult = ScrcpyDeviceMessage.deserialize(from: clipData)
    assertTrue(clipResult != nil, "Clipboard deserialization")
    assertEqual(clipResult?.bytesConsumed, clipData.count, "Bytes consumed")
    if case .clipboard(let str) = clipResult?.message {
        assertEqual(str, clipStr, "Clipboard string match")
    } else {
        fatalError("Expected .clipboard message")
    }
    print("  ✓ ScrcpyProtocol tests passed")
}

// MARK: - Server Command Line Flags Tests
print("[TEST] Scrcpy Server Command Line Flags Tests...")
do {
    Task { @MainActor in
        let client = ScrcpyClient()
        client.videoSource = .camera
        client.cameraFacing = .front
        client.stayAwake = true
        client.showTouches = true
        client.customServerArgs = "crop=1080:1080:0:0 angle=90"

        let cmd = client.buildServerCommandLine(scidHex: "12345678")
        assertTrue(cmd.contains("video_source=camera"), "Must contain video_source=camera")
        assertTrue(cmd.contains("camera_facing=front"), "Must contain camera_facing=front")
        assertTrue(cmd.contains("stay_awake=true"), "Must contain stay_awake=true")
        assertTrue(cmd.contains("show_touches=true"), "Must contain show_touches=true")
        assertTrue(cmd.contains("crop=1080:1080:0:0"), "Must contain custom crop argument")
        assertTrue(cmd.contains("angle=90"), "Must contain custom angle argument")
    }
    print("  ✓ Server flags tests passed")
}

// MARK: - NaluParser Tests
print("[TEST] NaluParser & AVCC Tests...")
do {
    var rawStream = Data()
    rawStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    rawStream.append(contentsOf: [0x67, 0x42, 0x00, 0x1f, 0x96, 0x35]) // SPS
    rawStream.append(contentsOf: [0x00, 0x00, 0x01])
    rawStream.append(contentsOf: [0x68, 0xce, 0x3c, 0x80])             // PPS
    rawStream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    rawStream.append(contentsOf: [0x65, 0x88, 0x84, 0x00, 0x33])       // IDR

    let units = NaluParser.parseAnnexB(data: rawStream)
    assertEqual(units.count, 3, "Parsed units count")
    assertTrue(units[0].isH264SPS, "is SPS")
    assertTrue(units[1].isH264PPS, "is PPS")
    assertTrue(units[2].isH264IDR, "is IDR")

    let avcc = NaluParser.convertToAvcc(nalUnits: units)
    assertEqual(avcc.count, 4 + 6 + 4 + 4 + 4 + 5, "AVCC total length")

    print("  ✓ NaluParser tests passed")
}

// MARK: - StreamRecorder Tests
print("[TEST] StreamRecorder Lifecycle & Directory Tests...")
do {
    let recDir = StreamRecorder.recordingsDirectory
    assertTrue(FileManager.default.fileExists(atPath: recDir.path), "Recordings directory created")

    let recorder = StreamRecorder()
    assertEqual(recorder.state, .idle, "Initial state idle")
    assertEqual(recorder.isRecording, false, "Initial isRecording false")

    recorder.startRecording(source: .camera, includeAudio: false, customFileName: "test_record.mp4")
    assertEqual(recorder.state, .waitingForFirstKeyframe, "State is waiting for keyframe")

    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let url = try await recorder.stopRecording()
            assertEqual(url, nil, "Cancelled recording returns nil when no keyframes fed")
            assertEqual(recorder.state, .idle, "State reset to idle")
        } catch {
            print("❌ Unexpected recorder error: \(error)")
            exit(1)
        }
        sema.signal()
    }
    sema.wait()
    print("  ✓ StreamRecorder lifecycle tests passed")
}

// MARK: - StreamRecorder Video + Audio Muxing & Normalized PTS Test
print("[TEST] StreamRecorder Video + Audio Muxing & Normalized PTS...")
do {
    let recorder = StreamRecorder()
    let filename = "test_muxing_pts_\(UUID().uuidString).mp4"
    recorder.startRecording(source: .camera, includeAudio: true, customFileName: filename)

    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_H264,
        width: 1280,
        height: 720,
        extensions: nil,
        formatDescriptionOut: &formatDesc
    )

    let initialPtsUs: Int64 = 50_000_000 // 50 seconds in
    func makeSample(ptsUs: Int64, isKey: Bool) -> CMSampleBuffer {
        var vData: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x25, 0x88, 0x84, 0x00, 0x10]
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: vData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: vData.count,
            flags: 0,
            blockBufferOut: &block
        )
        CMBlockBufferReplaceDataBytes(with: &vData, blockBuffer: block!, offsetIntoDestination: 0, dataLength: vData.count)
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        var sizes = [vData.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sample
        )
        if isKey {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)
            if let array = attachments as? [NSMutableDictionary], let dict = array.first {
                dict[kCMSampleAttachmentKey_DependsOnOthers] = kCFBooleanFalse
            }
        }
        return sample!
    }

    for i in 0..<30 {
        let pts = initialPtsUs + Int64(i * 33_333)
        let s = makeSample(ptsUs: pts, isKey: i == 0)
        recorder.appendVideoSample(s)

        let chunkFrames = 960
        let chunkSize = chunkFrames * 4
        let pcmData = Data(count: chunkSize)
        let audioPts = CMTime(value: pts, timescale: 1_000_000)
        recorder.appendAudioData(pcmData, pts: audioPts)
    }

    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let recordedURL = try await recorder.stopRecording()
            assertTrue(recordedURL != nil, "Recorded URL must not be nil")
            guard let url = recordedURL else { exit(1) }
            assertTrue(FileManager.default.fileExists(atPath: url.path), "MP4 file must exist")

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            print("  -> File size: \(fileSize) bytes")
            assertTrue(fileSize > 0, "File size must be > 0")
            assertTrue(fileSize < 100_000, "File size for 1 sec test must be small (< 100KB), not tens of MBs")

            try? FileManager.default.removeItem(at: url)
            print("  ✓ StreamRecorder Video + Audio Muxing & Normalized PTS passed")
        } catch {
            print("❌ Recording test failed: \(error)")
            exit(1)
        }
        sema.signal()
    }
    sema.wait()
}

print("========================================")
print("  All ScrcpyKit Tests Passed Successfully! ✓")
print("========================================")
