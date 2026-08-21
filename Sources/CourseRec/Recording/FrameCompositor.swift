import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// 屏幕与人像共用的合成器。录制和实时输出监看都走这里，避免“监看像、成片不像”。
final class FrameCompositor: @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    func render(
        frames: [(frame: CVPixelBuffer, layer: CompositionLayer)],
        outputSize: CGSize,
        into pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        let image = compose(frames: frames, outputSize: outputSize)

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        ciContext.render(image, to: pixelBuffer)
        return pixelBuffer
    }

    /// 把上一帧渐隐到新画面。过渡只发生在成片链路，不改变来源 ISO。
    func crossfade(
        from previous: CVPixelBuffer,
        to current: CVPixelBuffer,
        progress: Double,
        into pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        let amount = min(1, max(0, progress))
        guard amount < 1 else { return current }
        let canvas = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(current),
            height: CVPixelBufferGetHeight(current)
        )
        let fadedPrevious = CIImage(cvPixelBuffer: previous).applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - amount)
            ]
        )
        let image = fadedPrevious
            .composited(over: CIImage(cvPixelBuffer: current))
            .cropped(to: canvas)
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess,
              let result else { return nil }
        ciContext.render(image, to: result)
        return result
    }

    /// 生成轻量监看帧。输出限制在 1280×720 量级，不占用完整 Retina 帧的主线程带宽。
    func makePreview(
        frames: [(frame: CVPixelBuffer, layer: CompositionLayer)],
        outputSize requestedSize: CGSize
    ) -> CGImage? {
        let outputSize = Self.previewSize(for: requestedSize)
        let image = compose(frames: frames, outputSize: outputSize)
        return ciContext.createCGImage(image, from: CGRect(origin: .zero, size: outputSize))
    }

    private func compose(
        frames: [(frame: CVPixelBuffer, layer: CompositionLayer)],
        outputSize: CGSize
    ) -> CIImage {
        let canvas = CGRect(origin: .zero, size: outputSize)
        var output = CIImage(color: .black).cropped(to: canvas)

        func add(
            _ image: CIImage?,
            in rect: CGRect,
            mode: LayerDisplayMode,
            anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
        ) {
            guard let image else { return }
            output = place(image, in: rect, mode: mode, anchor: anchor).composited(over: output)
        }

        for value in frames where value.layer.isVisible {
            add(
                CIImage(cvPixelBuffer: value.frame),
                in: ciRect(value.layer.rect, outputSize: outputSize),
                mode: value.layer.displayMode,
                anchor: CGPoint(x: value.layer.anchorX, y: value.layer.anchorY)
            )
        }

        return output.cropped(to: canvas)
    }

    private func place(
        _ source: CIImage,
        in target: CGRect,
        mode: LayerDisplayMode,
        anchor: CGPoint
    ) -> CIImage {
        let normalized = source.transformed(
            by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
        )
        let xScale = target.width / normalized.extent.width
        let yScale = target.height / normalized.extent.height
        let scaled: CIImage
        switch mode {
        case .fit:
            let scale = min(xScale, yScale)
            scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        case .fill:
            let scale = max(xScale, yScale)
            scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        case .stretch:
            scaled = normalized.transformed(by: CGAffineTransform(scaleX: xScale, y: yScale))
        }
        let safeAnchorX = min(1, max(0, anchor.x))
        let safeAnchorY = min(1, max(0, anchor.y))
        let x: CGFloat
        let y: CGFloat
        if mode == .fit {
            x = target.midX - scaled.extent.width / 2
            y = target.midY - scaled.extent.height / 2
        } else {
            let excessWidth = max(0, scaled.extent.width - target.width)
            let excessHeight = max(0, scaled.extent.height - target.height)
            x = target.minX - excessWidth * safeAnchorX
            // primaryAnchorY 使用 UI 坐标（0 为上）；Core Image 坐标原点在左下。
            y = target.minY - excessHeight * (1 - safeAnchorY)
        }
        return scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: target)
    }

    /// UI 的 y 从上向下；Core Image 的 y 从下向上。
    private func ciRect(_ rect: NormalizedRect, outputSize: CGSize) -> CGRect {
        CGRect(
            x: rect.x * outputSize.width,
            y: (1 - rect.y - rect.height) * outputSize.height,
            width: rect.width * outputSize.width,
            height: rect.height * outputSize.height
        )
    }

    private static func previewSize(for source: CGSize) -> CGSize {
        let scale = min(1, min(1280 / source.width, 720 / source.height))
        let width = max(2, floor(source.width * scale / 2) * 2)
        let height = max(2, floor(source.height * scale / 2) * 2)
        return CGSize(width: width, height: height)
    }
}
