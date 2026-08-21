import AVFoundation
import Foundation

/// 摄像头/麦克风数据输出路由：把采集回调转给录制会话（独立小类，避免主线程跑帧）
final class CameraOutputRouter: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    var onVideoBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioLevel: ((_ average: Double, _ peak: Double, _ isClipping: Bool) -> Void)?
    private var lastMeterUpdate: TimeInterval = 0
    var gainDB = 0.0

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            onVideoBuffer?(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            let routedBuffer = Self.applyingGain(sampleBuffer, decibels: gainDB) ?? sampleBuffer
            onAudioBuffer?(routedBuffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeterUpdate >= 0.05,
               let sample = Self.measureAudioLevel(routedBuffer) {
                lastMeterUpdate = now
                onAudioLevel?(sample.average, sample.peak, sample.isClipping)
            }
        }
    }

    /// 输入由 AVCaptureAudioDataOutput 固定为 Float32 PCM；以 dBFS 映射到 0...1。
    private static func measureAudioLevel(
        _ sampleBuffer: CMSampleBuffer
    ) -> (average: Double, peak: Double, isClipping: Bool)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mBitsPerChannel == 32,
              description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = byteCount / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sumSquares = 0.0
        var rawPeak = 0.0
        for value in samples {
            let magnitude = abs(Double(value))
            sumSquares += magnitude * magnitude
            rawPeak = max(rawPeak, magnitude)
        }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return (
            normalizedDB(rms),
            normalizedDB(rawPeak),
            rawPeak >= 0.98
        )
    }

    private static func normalizedDB(_ amplitude: Double) -> Double {
        let db = 20 * log10(max(amplitude, 0.000_001))
        return min(1, max(0, (db + 60) / 60))
    }

    private static func applyingGain(
        _ sampleBuffer: CMSampleBuffer,
        decibels: Double
    ) -> CMSampleBuffer? {
        guard abs(decibels) > 0.01,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mBitsPerChannel == 32,
              description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let sourceBlock = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return sampleBuffer }

        let byteCount = CMBlockBufferGetDataLength(sourceBlock)
        guard byteCount > 0 else { return sampleBuffer }
        var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        let copyStatus = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                sourceBlock,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let multiplier = Float(pow(10, decibels / 20))
        for index in samples.indices {
            samples[index] = max(-1, min(1, samples[index] * multiplier))
        }

        var outputBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &outputBlock
        ) == kCMBlockBufferNoErr, let outputBlock else { return nil }
        let replaceStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: outputBlock,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var output: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: outputBlock,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            packetDescriptions: nil,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }
}
