import AVFoundation
import CoreMedia
import VideoToolbox

/// 将 AndroidScreenMonitor 的 Annex-B H.264/H.265 access unit 硬解成像素样本。
final class MobileVideoDecoder: @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    var onDecodeFailure: (@Sendable () -> Void)?

    private let isHEVC: Bool
    private let timeline: MobileTimeline
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    init(codec: String, timeline: MobileTimeline) {
        isHEVC = codec == MobileWire.codecH265
        self.timeline = timeline
    }

    deinit {
        invalidate()
    }

    func decode(_ frame: MobileFrame) {
        let units = Self.splitNALUnits(frame.data)
        guard !units.isEmpty else { return }

        var videoUnits: [[UInt8]] = []
        var parametersChanged = false
        for unit in units where !unit.isEmpty {
            let type = isHEVC ? Int((unit[0] >> 1) & 0x3F) : Int(unit[0] & 0x1F)
            if isHEVC {
                switch type {
                case 32: parametersChanged = replace(&vps, with: unit) || parametersChanged
                case 33: parametersChanged = replace(&sps, with: unit) || parametersChanged
                case 34: parametersChanged = replace(&pps, with: unit) || parametersChanged
                case 0 ... 31: videoUnits.append(unit)
                default: break
                }
            } else {
                switch type {
                case 7: parametersChanged = replace(&sps, with: unit) || parametersChanged
                case 8: parametersChanged = replace(&pps, with: unit) || parametersChanged
                case 1 ... 5: videoUnits.append(unit)
                default: break
                }
            }
        }

        if parametersChanged, formatDescription != nil {
            resetSession()
        }
        guard ensureSession(),
              let formatDescription,
              let session,
              !videoUnits.isEmpty,
              let sampleBuffer = Self.makeCompressedSample(
                  nals: videoUnits,
                  format: formatDescription,
                  isKeyframe: frame.isKeyframe,
                  presentationTime: timeline.time(forRemoteUs: frame.ptsUs)
              )
        else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            onDecodeFailure?()
        }
    }

    func invalidate() {
        resetSession()
        vps = nil
        sps = nil
        pps = nil
    }

    private func replace(_ current: inout [UInt8]?, with value: [UInt8]) -> Bool {
        guard current != value else { return false }
        current = value
        return true
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard ensureFormatDescription(), let formatDescription else { return false }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, duration in
                guard let refcon else { return }
                let decoder = Unmanaged<MobileVideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    decoder.onDecodeFailure?()
                    return
                }
                guard let sample = MobileVideoDecoder.makeDecodedSample(
                    imageBuffer: imageBuffer,
                    presentationTime: pts,
                    duration: duration
                ) else { return }
                decoder.onSampleBuffer?(sample)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { return false }
        VTSessionSetProperty(
            created,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        session = created
        return true
    }

    private func ensureFormatDescription() -> Bool {
        if formatDescription != nil { return true }
        if isHEVC {
            guard let vps, let sps, let pps else { return false }
            vps.withUnsafeBufferPointer { vpsPointer in
                sps.withUnsafeBufferPointer { spsPointer in
                    pps.withUnsafeBufferPointer { ppsPointer in
                        let pointers = [
                            vpsPointer.baseAddress!,
                            spsPointer.baseAddress!,
                            ppsPointer.baseAddress!
                        ]
                        let sizes = [vps.count, sps.count, pps.count]
                        var description: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &description
                        )
                        if status == noErr { formatDescription = description }
                    }
                }
            }
        } else {
            guard let sps, let pps else { return false }
            sps.withUnsafeBufferPointer { spsPointer in
                pps.withUnsafeBufferPointer { ppsPointer in
                    let pointers = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    var description: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                    if status == noErr { formatDescription = description }
                }
            }
        }
        return formatDescription != nil
    }

    private func resetSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private static func makeCompressedSample(
        nals: [[UInt8]],
        format: CMVideoFormatDescription,
        isKeyframe: Bool,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        avcc.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let length = UInt32(nal.count)
            avcc.append(UInt8(truncatingIfNeeded: length >> 24))
            avcc.append(UInt8(truncatingIfNeeded: length >> 16))
            avcc.append(UInt8(truncatingIfNeeded: length >> 8))
            avcc.append(UInt8(truncatingIfNeeded: length))
            avcc.append(contentsOf: nal)
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let replaceStatus = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        if !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sample,
               createIfNecessary: true
           ),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    private static func makeDecodedSample(
        imageBuffer: CVImageBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime.isValid
                ? presentationTime
                : CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    private static func splitNALUnits(_ data: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var index = 0

        func startCodeLength(at offset: Int) -> Int {
            if offset + 3 < data.count,
               data[offset] == 0, data[offset + 1] == 0,
               data[offset + 2] == 0, data[offset + 3] == 1 {
                return 4
            }
            if offset + 2 < data.count,
               data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 1 {
                return 3
            }
            return 0
        }

        while index < data.count, startCodeLength(at: index) == 0 { index += 1 }
        while index < data.count {
            let codeLength = startCodeLength(at: index)
            guard codeLength > 0 else { index += 1; continue }
            let start = index + codeLength
            var end = start
            while end < data.count, startCodeLength(at: end) == 0 { end += 1 }
            if start < end { units.append(Array(data[start ..< end])) }
            index = end
        }
        return units
    }
}
