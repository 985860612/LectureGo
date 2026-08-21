import AVFoundation
import Foundation

private struct MonitorSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

/// 单路耳机监听。只播放采集样本，不参与成片和 ISO 路由。
final class AudioSourceMonitor: @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "courserec.audio.monitor", qos: .userInteractive)
    private var started = false

    init() {
        synchronizer.addRenderer(renderer)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let sample = MonitorSampleBuffer(value: sampleBuffer)
        queue.async { [self] in
            guard sample.value.isValid else { return }
            if renderer.status == .failed {
                renderer.flush()
                started = false
            }
            guard renderer.isReadyForMoreMediaData else { return }
            if !started {
                synchronizer.setRate(
                    1,
                    time: CMSampleBufferGetPresentationTimeStamp(sample.value)
                )
                started = true
            }
            renderer.enqueue(sample.value)
        }
    }

    func stop() {
        queue.async { [self] in
            synchronizer.rate = 0
            renderer.flush()
            started = false
        }
    }
}
