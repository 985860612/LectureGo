@preconcurrency import AVFoundation
import SwiftUI

/// 摄像头实时预览（AVCaptureVideoPreviewLayer 桥接）
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.frame = bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

/// 移动端硬解帧预览。只保留尚未提交给主线程的最新一帧，避免 UI 忙时累积延迟。
final class MobilePreviewRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var view: MobileSampleBufferPreviewNSView?
    private var latestSample: CMSampleBuffer?
    private var deliveryScheduled = false

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let shouldSchedule = lock.withLock { () -> Bool in
            latestSample = sampleBuffer
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
    }

    @MainActor
    func attach(_ view: MobileSampleBufferPreviewNSView) {
        lock.withLock { self.view = view }
        deliverLatest()
    }

    @MainActor
    func detach(_ view: MobileSampleBufferPreviewNSView) {
        lock.withLock {
            if self.view === view { self.view = nil }
        }
    }

    func flush() {
        let attached = lock.withLock { () -> MobileSampleBufferPreviewNSView? in
            latestSample = nil
            return view
        }
        DispatchQueue.main.async { attached?.flush() }
    }

    @MainActor
    private func deliverLatest() {
        let delivery = lock.withLock { () -> (MobileSampleBufferPreviewNSView?, CMSampleBuffer?) in
            let result = (view, latestSample)
            latestSample = nil
            deliveryScheduled = false
            return result
        }
        guard let view = delivery.0, let sample = delivery.1 else { return }
        view.display(sample)

        // enqueue() 可能在本次主线程提交期间写入了更新帧；继续交付最新值即可。
        let shouldSchedule = lock.withLock { () -> Bool in
            guard latestSample != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
        }
    }
}

struct MobileSampleBufferPreviewView: NSViewRepresentable {
    let renderer: MobilePreviewRenderer

    func makeNSView(context: Context) -> MobileSampleBufferPreviewNSView {
        let view = MobileSampleBufferPreviewNSView()
        renderer.attach(view)
        return view
    }

    func updateNSView(_ nsView: MobileSampleBufferPreviewNSView, context: Context) {
        renderer.attach(nsView)
    }

    static func dismantleNSView(_ nsView: MobileSampleBufferPreviewNSView, coordinator: ()) {
        nsView.flush()
    }
}

final class MobileSampleBufferPreviewNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func display(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }

        var immediateSample: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &immediateSample
        ) == noErr, let immediateSample else { return }
        CMSetAttachment(
            immediateSample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        displayLayer.enqueue(immediateSample)
        needsDisplay = true
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}
