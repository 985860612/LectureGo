import AudioToolbox
import AVFoundation
import Foundation

/// Wraps Android MediaCodec AAC access units as compressed CMSampleBuffers.
/// AVAssetWriter can pass these through without an unnecessary decode/re-encode cycle.
final class MobileAudioSampleBuilder: @unchecked Sendable {
    private let sampleRate: Int
    private let channels: Int
    private let timeline: MobileTimeline
    private var formatDescription: CMAudioFormatDescription?

    init(sampleRate: Int, channels: Int, timeline: MobileTimeline) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.timeline = timeline
    }

    func consume(_ frame: MobileFrame) -> CMSampleBuffer? {
        if frame.isConfig {
            formatDescription = makeFormatDescription(magicCookie: frame.data)
            return nil
        }
        guard let formatDescription else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.data.count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        guard frame.data.withUnsafeBytes({ raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: frame.data.count
            )
        }) == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1_024, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: timeline.time(forRemoteUs: frame.ptsUs),
            decodeTimeStamp: .invalid
        )
        var size = frame.data.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    private func makeFormatDescription(magicCookie: [UInt8]) -> CMAudioFormatDescription? {
        let esdsCookie = makeESDSMagicCookie(audioSpecificConfig: magicCookie)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = esdsCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: esdsCookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    /// Android MediaCodec 的 csd-0 是裸 AudioSpecificConfig（通常 2 字节），
    /// CoreMedia 的 AAC magic cookie 则要求完整 ES_Descriptor。
    /// 直接塞裸 ASC 会生成损坏的 `esds` atom：ffmpeg 勉强可读，AVFoundation 无法读取。
    private func makeESDSMagicCookie(audioSpecificConfig: [UInt8]) -> [UInt8] {
        guard audioSpecificConfig.first != 0x03 else { return audioSpecificConfig }

        let decoderSpecific = descriptor(tag: 0x05, payload: audioSpecificConfig)
        let decoderConfig = descriptor(tag: 0x04, payload: [
            0x40,             // MPEG-4 Audio
            0x14,             // audio stream
            0x00, 0x18, 0x00, // decoder buffer size
            0x00, 0x01, 0xF4, 0x00, // max bitrate: 128 kbps
            0x00, 0x00, 0x00, 0x00  // average bitrate: unspecified
        ] + decoderSpecific)
        let slConfig = descriptor(tag: 0x06, payload: [0x02])
        return descriptor(
            tag: 0x03,
            payload: [0x00, 0x00, 0x00] + decoderConfig + slConfig
        )
    }

    private func descriptor(tag: UInt8, payload: [UInt8]) -> [UInt8] {
        let count = payload.count
        let encodedLength = [
            UInt8(0x80 | ((count >> 21) & 0x7F)),
            UInt8(0x80 | ((count >> 14) & 0x7F)),
            UInt8(0x80 | ((count >> 7) & 0x7F)),
            UInt8(count & 0x7F)
        ]
        return [tag] + encodedLength + payload
    }
}
