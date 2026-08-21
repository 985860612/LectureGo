import AVFoundation
import Foundation

/// 一路局域网移动端输入：控制握手、UDP 收帧、硬解、看门狗与自动重连。
final class MobileInputClient: @unchecked Sendable {
    var onVideo: (@Sendable (CMSampleBuffer) -> Void)?
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onStreamInfo: (@Sendable (MobileControlClient.StreamInfo) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    private let stateLock = NSLock()
    private var generation = UUID()
    private var control: MobileControlClient?
    private var receiver: MobileMediaReceiver?
    private var decoder: MobileVideoDecoder?
    private var lastFrameAt = Date.distantPast
    private var lastRecoveryKeyframeAt = Date.distantPast

    func start(streamer: MobileStreamer, expectedKind: MobileSourceKind) {
        stop()
        let token = UUID()
        stateLock.withLock { generation = token }
        Thread.detachNewThread { [weak self] in
            self?.supervise(streamer: streamer, expectedKind: expectedKind, token: token)
        }
    }

    func stop() {
        let resources = stateLock.withLock { () -> (
            MobileControlClient?, MobileMediaReceiver?, MobileVideoDecoder?
        ) in
            generation = UUID()
            let current = (control, receiver, decoder)
            control = nil
            receiver = nil
            decoder = nil
            return current
        }
        resources.0?.close()
        resources.1?.stop()
        resources.2?.invalidate()
    }

    private func supervise(
        streamer: MobileStreamer,
        expectedKind: MobileSourceKind,
        token: UUID
    ) {
        while isCurrent(token) {
            onStatus?("正在连接 \(streamer.host)…")
            let control = MobileControlClient()
            let receiver = MobileMediaReceiver()
            do {
                try receiver.start()
                let info = try control.connect(
                    host: streamer.host,
                    controlPort: streamer.controlPort,
                    mediaPort: receiver.listeningPort
                )
                let actualKind: MobileSourceKind = info.sourceKind == .unknown ? .screen : info.sourceKind
                guard actualKind == expectedKind else {
                    throw NSError(
                        domain: "CourseRec.MobileInput",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "移动端当前发送的是\(actualKind.label)，需要\(expectedKind.label)"]
                    )
                }
                guard isCurrent(token) else {
                    control.close()
                    receiver.stop()
                    return
                }

                receiver.setExpectedHost(info.peerHost)
                let timeline = MobileTimeline()
                let decoder = MobileVideoDecoder(codec: info.codec, timeline: timeline)
                let audioBuilder: MobileAudioSampleBuilder? = {
                    guard info.audioCodec == MobileWire.audioCodecAAC,
                          let rate = info.audioSampleRate,
                          let channels = info.audioChannels,
                          rate > 0,
                          channels > 0
                    else { return nil }
                    return MobileAudioSampleBuilder(
                        sampleRate: rate,
                        channels: channels,
                        timeline: timeline
                    )
                }()
                decoder.onSampleBuffer = { [weak self] sample in
                    guard let self, self.isCurrent(token) else { return }
                    self.stateLock.withLock { self.lastFrameAt = Date() }
                    self.onVideo?(sample)
                }
                decoder.onDecodeFailure = { [weak self, weak control] in
                    guard let self, let control else { return }
                    self.requestRecoveryKeyframe(control: control, token: token)
                }
                receiver.onVideoLoss = { [weak self, weak control] in
                    guard let self, let control else { return }
                    self.requestRecoveryKeyframe(control: control, token: token)
                }
                receiver.onFrame = { [weak self, weak decoder] frame in
                    guard let self, self.isCurrent(token) else { return }
                    if frame.isAudio {
                        if let sample = audioBuilder?.consume(frame) { self.onAudio?(sample) }
                    } else {
                        decoder?.decode(frame)
                    }
                }

                let accepted = stateLock.withLock { () -> Bool in
                    guard generation == token else { return false }
                    self.control = control
                    self.receiver = receiver
                    self.decoder = decoder
                    self.lastFrameAt = Date()
                    self.lastRecoveryKeyframeAt = Date()
                    return true
                }
                guard accepted else {
                    control.close()
                    receiver.stop()
                    decoder.invalidate()
                    return
                }
                control.requestKeyframe()
                onStreamInfo?(info)
                let audio = info.audioCodec == nil ? "纯视频" : "AAC \(info.audioSampleRate ?? 0)Hz"
                onStatus?("已连接 \(info.width)×\(info.height) \(info.codec.uppercased()) · \(audio)")

                var nextKeepAlive = Date().addingTimeInterval(4)
                while isCurrent(token) {
                    Thread.sleep(forTimeInterval: 0.5)
                    let lastFrame = stateLock.withLock { lastFrameAt }
                    if Date().timeIntervalSince(lastFrame) > 6 { break }
                    if Date() >= nextKeepAlive {
                        control.keepAlive()
                        nextKeepAlive = Date().addingTimeInterval(4)
                    }
                }
            } catch {
                if isCurrent(token) {
                    onStatus?(error.localizedDescription)
                }
            }

            control.close()
            receiver.stop()
            let oldDecoder = stateLock.withLock { () -> MobileVideoDecoder? in
                guard generation == token else { return nil }
                self.control = nil
                self.receiver = nil
                let current = decoder
                self.decoder = nil
                return current
            }
            oldDecoder?.invalidate()
            guard isCurrent(token) else { return }
            onStatus?("移动端断开，2 秒后重连…")
            for _ in 0 ..< 20 where isCurrent(token) {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        stateLock.withLock { generation == token }
    }

    private func requestRecoveryKeyframe(control: MobileControlClient, token: UUID) {
        let now = Date()
        let shouldRequest = stateLock.withLock { () -> Bool in
            guard generation == token,
                  now.timeIntervalSince(lastRecoveryKeyframeAt) >= 0.35
            else { return false }
            lastRecoveryKeyframeAt = now
            return true
        }
        if shouldRequest { control.requestKeyframe() }
    }
}
