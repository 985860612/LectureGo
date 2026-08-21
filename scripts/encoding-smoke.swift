import AVFoundation
import CoreVideo
import Foundation

@main
struct EncodingSmokeTest {
    static func main() throws {
        let output = URL(fileURLWithPath: "/tmp/courserec-encoding-smoke.mov")
        try? FileManager.default.removeItem(at: output)
        let size = (width: 1280, height: 720)
        let writer = try TrackWriter(
            url: output,
            videoSize: size,
            videoBitRate: 8_000_000,
            videoCodec: .hevc,
            expectedFrameRate: 24,
            needsPixelBufferAdaptor: true
        )
        writer.startIfNeeded(t0: .zero)
        guard let pool = writer.pixelBufferPool else {
            throw SmokeError.missingPixelBufferPool
        }

        let primary = try makePixelBuffer(width: 1920, height: 1080, byte: 42)
        let secondary = try makePixelBuffer(width: 1280, height: 720, byte: 180)
        let third = try makePixelBuffer(width: 720, height: 1280, byte: 95)
        let fourth = try makePixelBuffer(width: 640, height: 360, byte: 220)
        let frames = [
            (frame: primary, layer: CompositionLayer(
                sourceID: UUID(),
                rect: NormalizedRect(x: 0.08, y: 0.10, width: 0.72, height: 0.68),
                displayMode: .stretch
            )),
            (frame: secondary, layer: CompositionLayer(
                sourceID: UUID(),
                rect: NormalizedRect(x: 0.70, y: 0.62, width: 0.28, height: 0.34)
            )),
            (frame: third, layer: CompositionLayer(
                sourceID: UUID(),
                rect: NormalizedRect(x: 0.67, y: 0.08, width: 0.22, height: 0.26)
            )),
            (frame: fourth, layer: CompositionLayer(
                sourceID: UUID(),
                rect: NormalizedRect(x: 0.12, y: 0.72, width: 0.28, height: 0.18),
                displayMode: .fit
            ))
        ]
        let compositor = FrameCompositor()
        for frame in 0 ..< 48 {
            guard let rendered = compositor.render(
                frames: frames,
                outputSize: CGSize(width: size.width, height: size.height),
                into: pool
            ) else { throw SmokeError.renderFailed }
            let time = CMTime(value: CMTimeValue(frame), timescale: 24)
            while !writer.appendPixelBuffer(rendered, at: time) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finish { semaphore.signal() }
        semaphore.wait()
        print(output.path)
    }

    private static func makePixelBuffer(width: Int, height: Int, byte: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw SmokeError.pixelBufferCreationFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(byte), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

private enum SmokeError: Error {
    case missingPixelBufferPool
    case pixelBufferCreationFailed
    case renderFailed
}
