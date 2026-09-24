import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation

public final class VideoToolboxDecoder: @unchecked Sendable {
    public let codec: ScrcpyVideoCodec
    public private(set) var formatDescription: CMFormatDescription?

    private var spsData: Data?
    private var ppsData: Data?
    private var vpsData: Data?

    // Metrics
    public private(set) var frameCount: Int = 0
    public private(set) var currentFps: Double = 0.0
    private var lastFpsTimestamp: TimeInterval = 0
    private var fpsFrameCounter: Int = 0

    public var onSampleBufferDecoded: (@Sendable (CMSampleBuffer) -> Void)?
    public var onDimensionsChanged: (@Sendable (Int, Int) -> Void)?
    private var sampleBufferListeners: [@Sendable (CMSampleBuffer) -> Void] = []

    public func addSampleBufferListener(_ listener: @escaping @Sendable (CMSampleBuffer) -> Void) {
        sampleBufferListeners.append(listener)
    }

    public init(codec: ScrcpyVideoCodec = .h264) {
        self.codec = codec
    }

    /// Feeds raw packet data from scrcpy video stream
    public func decodePacket(data: Data, pts: UInt64, isConfig: Bool, isKeyFrame: Bool) {
        let naluUnits = NaluParser.parseAnnexB(data: data)

        if isConfig || formatDescription == nil {
            extractParameters(from: naluUnits)
        }

        // If this is purely a config packet without slice data, we're done updating format
        let sliceUnits = naluUnits.filter { unit in
            if codec == .h264 {
                return !unit.isH264SPS && !unit.isH264PPS
            } else {
                return !unit.isH265VPS && !unit.isH265SPS && !unit.isH265PPS
            }
        }

        guard !sliceUnits.isEmpty, let format = formatDescription else { return }

        // Convert slices to AVCC/HVCC length-prefixed format
        let avccData = NaluParser.convertToAvcc(nalUnits: sliceUnits)
        guard let sampleBuffer = createSampleBuffer(from: avccData, formatDescription: format, ptsUs: pts, isKeyFrame: isKeyFrame) else {
            return
        }

        // Update statistics
        frameCount += 1
        fpsFrameCounter += 1
        let now = ProcessInfo.processInfo.systemUptime
        if lastFpsTimestamp == 0 {
            lastFpsTimestamp = now
        } else if now - lastFpsTimestamp >= 1.0 {
            currentFps = Double(fpsFrameCounter) / (now - lastFpsTimestamp)
            fpsFrameCounter = 0
            lastFpsTimestamp = now
        }

        onSampleBufferDecoded?(sampleBuffer)
        for listener in sampleBufferListeners {
            listener(sampleBuffer)
        }
    }

    private func extractParameters(from units: [NaluUnit]) {
        if codec == .h264 {
            for unit in units {
                if unit.isH264SPS {
                    self.spsData = unit.data
                } else if unit.isH264PPS {
                    self.ppsData = unit.data
                }
            }

            guard let sps = spsData, let pps = ppsData else { return }

            var parameterSets: [UnsafePointer<UInt8>] = []
            var parameterSetSizes: [Int] = []

            sps.withUnsafeBytes { spsBuffer in
                pps.withUnsafeBytes { ppsBuffer in
                    if let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                       let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress {
                        parameterSets = [spsPtr, ppsPtr]
                        parameterSetSizes = [sps.count, pps.count]

                        var newFormat: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: parameterSets,
                            parameterSetSizes: parameterSetSizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormat
                        )

                        if status == noErr, let format = newFormat {
                            self.formatDescription = format
                            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                            self.onDimensionsChanged?(Int(dimensions.width), Int(dimensions.height))
                        }
                    }
                }
            }
        } else if codec == .h265 {
            for unit in units {
                if unit.isH265VPS {
                    self.vpsData = unit.data
                } else if unit.isH265SPS {
                    self.spsData = unit.data
                } else if unit.isH265PPS {
                    self.ppsData = unit.data
                }
            }

            guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return }

            vps.withUnsafeBytes { vpsBuf in
                sps.withUnsafeBytes { spsBuf in
                    pps.withUnsafeBytes { ppsBuf in
                        guard let vpsPtr = vpsBuf.bindMemory(to: UInt8.self).baseAddress,
                              let spsPtr = spsBuf.bindMemory(to: UInt8.self).baseAddress,
                              let ppsPtr = ppsBuf.bindMemory(to: UInt8.self).baseAddress else { return }

                        let pointers = [vpsPtr, spsPtr, ppsPtr]
                        let sizes = [vps.count, sps.count, pps.count]

                        var newFormat: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &newFormat
                        )

                        if status == noErr, let format = newFormat {
                            self.formatDescription = format
                            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                            self.onDimensionsChanged?(Int(dimensions.width), Int(dimensions.height))
                        }
                    }
                }
            }
        }
    }

    private func createSampleBuffer(from avccData: Data, formatDescription: CMFormatDescription, ptsUs: UInt64, isKeyFrame: Bool) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?

        let dataLen = avccData.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLen,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLen,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        avccData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            status = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataLen
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: Int64(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [dataLen]

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else { return nil }

        // Set sample buffer attachments for keyframe / display
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
        if let array = attachments as? [NSMutableDictionary], let dict = array.first {
            if isKeyFrame {
                dict[kCMSampleAttachmentKey_DependsOnOthers] = kCFBooleanFalse
            }
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }

        return sample
    }

    public func reset() {
        formatDescription = nil
        spsData = nil
        ppsData = nil
        vpsData = nil
        frameCount = 0
        currentFps = 0.0
        lastFpsTimestamp = 0
        fpsFrameCounter = 0
    }
}
