import AVFoundation

/// 网络流使用各自时间轴；进入录制管线前统一映射到本机 host clock。
enum VideoSampleRetimer {
    static func retimedToHostClock(_ source: CMSampleBuffer) -> CMSampleBuffer? {
        guard source.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(source)
        else { return nil }

        var format = CMSampleBufferGetFormatDescription(source)
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &format
            )
        }
        guard let format else { return nil }

        let sourceDuration = CMSampleBufferGetDuration(source)
        var timing = CMSampleTimingInfo(
            duration: sourceDuration.isValid ? sourceDuration : .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }
}
