import AVFoundation
import CoreVideo
import Foundation

@main
struct CrashRecoverySmokeTest {
    static func main() throws {
        let output = URL(fileURLWithPath: "/tmp/courserec-crash-recovery.mov")
        let partial = URL(fileURLWithPath: "/tmp/courserec-crash-recovery.partial.mov")
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: partial)
        let writer = try TrackWriter(
            url: output,
            videoSize: (320, 180),
            videoBitRate: 1_000_000,
            videoCodec: .h264,
            expectedFrameRate: 30,
            needsPixelBufferAdaptor: true
        )
        writer.startIfNeeded(t0: .zero)
        guard let pool = writer.pixelBufferPool else { exit(2) }
        for index in 0 ..< 390 {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { exit(3) }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                memset(address, Int32(index % 255), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            while !writer.appendPixelBuffer(pixel, at: time) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        Thread.sleep(forTimeInterval: 1)
        // 故意不调用 finish，模拟进程异常退出。
        exit(0)
    }
}
