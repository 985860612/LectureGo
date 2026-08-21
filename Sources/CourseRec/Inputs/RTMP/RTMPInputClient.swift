@preconcurrency import AVFoundation
import AppKit
import Foundation
import HaishinKit
import RTMPHaishinKit

/// RTMP/RTMPS playback 输入。HaishinKit 解复用并硬解，输出统一映射到本机时间轴。
final class RTMPInputClient: @unchecked Sendable {
    var onVideo: (@Sendable (CMSampleBuffer) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    private let stateLock = NSLock()
    private let playbackClock = AudioPlayer(audioEngine: AVAudioEngine())
    private let videoOutput = RTMPVideoOutputBridge()
    private var generation = UUID()
    private var runner: Task<Void, Never>?
    private var session: (any Session)?

    init() {
        videoOutput.onVideo = { [weak self] video in
            guard let retimed = VideoSampleRetimer.retimedToHostClock(video) else { return }
            self?.onVideo?(retimed)
        }
    }

    func start(urlString: String) {
        stop()
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              url.host != nil
        else {
            onStatus?("RTMP 地址无效，应以 rtmp:// 或 rtmps:// 开头")
            return
        }

        let token = UUID()
        stateLock.withLock { generation = token }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.supervise(url: url, token: token)
        }
        stateLock.withLock { runner = task }
    }

    func stop() {
        let current = stateLock.withLock { () -> (Task<Void, Never>?, (any Session)?) in
            generation = UUID()
            let result = (runner, session)
            runner = nil
            session = nil
            return result
        }
        current.0?.cancel()
        if let session = current.1 {
            Task { try? await session.close() }
        }
    }

    private func supervise(url: URL, token: UUID) async {
        await SessionBuilderFactory.shared.register(RTMPSessionFactory())
        while isCurrent(token), !Task.isCancelled {
            onStatus?("正在连接 RTMP…")
            do {
                let builder = try await SessionBuilderFactory.shared.make(url)
                let built = try await builder.setMode(.playback).build()
                guard let built else { throw RTMPInputError.sessionCreationFailed }
                guard isCurrent(token), !Task.isCancelled else {
                    try? await built.close()
                    return
                }

                let stream = await built.stream
                await stream.attachAudioPlayer(playbackClock)
                await stream.setSoundTransform(SoundTransform(volume: 0))
                await stream.addOutput(videoOutput)
                let accepted = stateLock.withLock { () -> Bool in
                    guard generation == token else { return false }
                    session = built
                    return true
                }
                guard accepted else {
                    await stream.removeOutput(videoOutput)
                    await stream.attachAudioPlayer(nil)
                    try? await built.close()
                    return
                }
                try await built.connect { [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.onStatus?("RTMP 连接已断开")
                }
                guard isCurrent(token), !Task.isCancelled else {
                    try? await built.close()
                    return
                }
                onStatus?("RTMP 已连接")

                while isCurrent(token), !Task.isCancelled, await built.connected {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await stream.removeOutput(videoOutput)
                await stream.attachAudioPlayer(nil)
                try? await built.close()
            } catch is CancellationError {
                return
            } catch {
                if isCurrent(token), !Task.isCancelled {
                    onStatus?("RTMP 连接失败：\(error.localizedDescription)")
                }
            }

            stateLock.withLock {
                if generation == token { session = nil }
            }
            guard isCurrent(token), !Task.isCancelled else { return }
            onStatus?("RTMP 2 秒后重连…")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        stateLock.withLock { generation == token }
    }

}

/// HaishinKit 会根据 AppKit 视图类型决定是否持续开放播放样本；该桥接层不参与绘制。
private final class RTMPVideoOutputBridge: NSView, StreamOutput, @unchecked Sendable {
    /// 初始化后不再修改；HaishinKit 从解码线程调用 StreamOutput。
    nonisolated(unsafe) var onVideo: (@Sendable (CMSampleBuffer) -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated func stream(
        _ stream: some StreamConvertible,
        didOutput audio: AVAudioBuffer,
        when: AVAudioTime
    ) {
        // RTMP 只取视频，人声继续使用用户选择的音频来源。
    }

    nonisolated func stream(
        _ stream: some StreamConvertible,
        didOutput video: CMSampleBuffer
    ) {
        onVideo?(video)
    }
}

private enum RTMPInputError: LocalizedError {
    case sessionCreationFailed

    var errorDescription: String? {
        "无法创建 RTMP 播放会话"
    }
}
