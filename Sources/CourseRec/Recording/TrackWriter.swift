import AVFoundation
import Foundation
import VideoToolbox

struct TrackWriterResult: Sendable {
    let name: String
    let url: URL
    let succeeded: Bool
    let fileSize: Int64
    let videoFrames: Int
    let audioSamples: Int
    let failedAppends: Int
    let duration: TimeInterval
    let effectiveFrameRate: Double
    let errorText: String?

    func validated(succeeded: Bool, duration: TimeInterval, errorText: String?) -> TrackWriterResult {
        TrackWriterResult(
            name: name,
            url: url,
            succeeded: succeeded,
            fileSize: fileSize,
            videoFrames: videoFrames,
            audioSamples: audioSamples,
            failedAppends: failedAppends,
            duration: duration,
            effectiveFrameRate: effectiveFrameRate,
            errorText: errorText
        )
    }
}

struct TrackWriterSnapshot {
    let state: TrackWriter.State
    let videoFrames: Int
    let failedAppends: Int
    let duration: TimeInterval
    let effectiveFrameRate: Double
    let writtenBytes: Int64
    let errorText: String?
}

/// 单文件写入器：1 条可选视频轨 + 若干命名音频轨
/// 所有文件共用同一时间基线 t0，天然对齐
final class TrackWriter {
    enum State: String {
        case idle, writing, finishing, done, failed
    }

    let name: String
    /// 调试日志出口（由 RecordingSession 注入）
    var debug: ((String) -> Void)?

    private let outputURL: URL
    private let workingURL: URL
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInputs: [String: AVAssetWriterInput] = [:]
    private var passthroughAudioTracks: Set<String> = []
    private(set) var state: State = .idle
    private let lock = NSLock()

    private var appendedVideo = 0
    private var appendedAudio: [String: Int] = [:]
    private var failedAppends = 0
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var terminalError: String?

    var pixelBufferPool: CVPixelBufferPool? { pixelBufferAdaptor?.pixelBufferPool }

    var snapshot: TrackWriterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let duration: TimeInterval
        if let firstVideoTime, let lastVideoTime, appendedVideo > 1 {
            duration = max(0, CMTimeGetSeconds(CMTimeSubtract(lastVideoTime, firstVideoTime)))
        } else {
            duration = 0
        }
        return TrackWriterSnapshot(
            state: state,
            videoFrames: appendedVideo,
            failedAppends: failedAppends,
            duration: duration,
            effectiveFrameRate: duration > 0 ? Double(max(0, appendedVideo - 1)) / duration : 0,
            writtenBytes: ((try? FileManager.default.attributesOfItem(atPath: workingURL.path)[.size]) as? NSNumber)?.int64Value ?? 0,
            errorText: terminalError
        )
    }

    /// - Parameters:
    ///   - videoSize: 传 nil 表示纯音频文件
    ///   - needsPixelBufferAdaptor: true 表示视频帧由外部合成后推入（而非直接 append 样本）
    ///   - audioTracks: 命名音轨，如 ["mic"] / ["sys"] / ["mic", "sys"]
    init(
        url: URL,
        videoSize: (width: Int, height: Int)? = nil,
        videoBitRate: Int = 8_000_000,
        videoCodec: AVVideoCodecType = .h264,
        expectedFrameRate: Int = 30,
        needsPixelBufferAdaptor: Bool = false,
        audioTracks: [String] = [],
        audioFormatHints: [String: CMFormatDescription] = [:]
    ) throws {
        name = url.lastPathComponent
        outputURL = url
        workingURL = url.deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: workingURL)
        writer = try AVAssetWriter(
            outputURL: workingURL,
            fileType: url.pathExtension == "m4a" ? .m4a : .mov
        )
        if url.pathExtension != "m4a" {
            // 定期写入可恢复的 moov 片段；异常退出时保留 .partial.mov 供修复。
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        }
        if let size = videoSize {
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: videoCodec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                    : AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: expectedFrameRate * 2
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: videoCodec,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: compression
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            videoInput = input
            if needsPixelBufferAdaptor {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: size.width,
                    kCVPixelBufferHeightKey as String: size.height
                ]
                pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: attributes
                )
            }
        }
        for track in audioTracks {
            let input: AVAssetWriterInput
            let formatHint = audioFormatHints[track]
            let sourceASBD = formatHint.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
            let isCompressed = sourceASBD?.pointee.mFormatID == kAudioFormatMPEG4AAC
            if isCompressed {
                // Android 已硬编 AAC；必须拿到 formatHint 后才能安全创建直通输入。
                input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: formatHint
                )
                passthroughAudioTracks.insert(track)
            } else if let formatHint {
                // 本机麦克风/ScreenCaptureKit 提供 PCM，由 AVAssetWriter 编 AAC。
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVEncoderBitRateStrategyKey: "AVAudioBitRateStrategy_Variable"
                ]
                input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: settings,
                    sourceFormatHint: formatHint
                )
            } else {
                // ScreenCaptureKit 已固定请求 48 kHz 双声道。未提供源格式提示时，
                // AVAssetWriterInput 要求完整设置，否则会抛 NSInvalidArgumentException。
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateStrategyKey: "AVAudioBitRateStrategy_Variable"
                ]
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            }
            input.expectsMediaDataInRealTime = true
            audioInputs[track] = input
        }
        debug?("\(name): 创建 video=\(videoSize?.width ?? 0)x\(videoSize?.height ?? 0) tracks=\(audioTracks)")
    }

    /// 首个样本到达时调用一次；t0 为跨文件统一时间基线
    func startIfNeeded(t0: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { return }
        if let video = videoInput {
            guard writer.canAdd(video) else {
                failLocked("无法添加视频轨")
                return
            }
            writer.add(video)
        }
        for (track, input) in audioInputs {
            guard writer.canAdd(input) else {
                failLocked("无法添加音频轨 \(track)")
                return
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            failLocked("开始写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
            return
        }
        writer.startSession(atSourceTime: t0)
        state = .writing
        debug?("\(name): 开始写入 t0=\(CMTimeGetSeconds(t0))")
    }

    @discardableResult
    func appendVideo(_ buffer: CMSampleBuffer) -> Bool {
        let ok = append(buffer, to: videoInput, label: "video")
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock()
        if ok {
            appendedVideo += 1
            noteVideoTimeLocked(time)
        } else {
            failedAppends += 1
        }
        lock.unlock()
        return ok
    }

    /// 推送外部合成好的像素缓冲（成片路径）
    @discardableResult
    func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .writing,
              let adaptor = pixelBufferAdaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData else {
            failedAppends += 1
            return false
        }
        let ok = adaptor.append(pixelBuffer, withPresentationTime: time)
        if ok {
            appendedVideo += 1
            noteVideoTimeLocked(time)
        } else {
            failedAppends += 1
            if writer.status == .failed {
                failLocked("合成画面写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
            }
        }
        return ok
    }

    @discardableResult
    func appendAudio(_ buffer: CMSampleBuffer, track: String) -> Bool {
        let ok: Bool
        if let mismatch = audioFormatMismatch(buffer, track: track) {
            lock.lock()
            failLocked("audio:\(track) 写入格式不匹配：\(mismatch)")
            lock.unlock()
            ok = false
        } else {
            ok = append(buffer, to: audioInputs[track], label: "audio:\(track)")
        }
        lock.lock()
        if ok {
            appendedAudio[track, default: 0] += 1
        } else {
            failedAppends += 1
        }
        lock.unlock()
        return ok
    }

    /// AVAssetWriterInput 的格式不匹配会抛 Objective-C 异常，Swift 无法用 do/catch 捕获。
    /// append 前主动拦截，确保异常媒体数据只让当前录制失败，不会带崩整个应用。
    private func audioFormatMismatch(_ buffer: CMSampleBuffer, track: String) -> String? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return "样本缺少音频格式描述" }
        let formatID = asbd.pointee.mFormatID
        if passthroughAudioTracks.contains(track) {
            return formatID == kAudioFormatLinearPCM ? "直通音轨收到未压缩 PCM" : nil
        }
        return formatID == kAudioFormatLinearPCM
            ? nil
            : "编码音轨收到压缩格式 \(Self.fourCC(formatID))"
    }

    private static func fourCC(_ value: AudioFormatID) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?, label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .writing, let input else { return false }
        guard input.isReadyForMoreMediaData else { return false }
        let ok = input.append(buffer)
        if !ok {
            failLocked("\(label) 写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
        }
        return ok
    }

    func finish(completion: @escaping (TrackWriterResult) -> Void) {
        lock.lock()
        guard state == .writing else {
            let currentState = state
            lock.unlock()
            debug?("\(name): finish 时状态=\(currentState.rawValue)（未写入，清理空文件）video=\(appendedVideo) audio=\(appendedAudio) failed=\(failedAppends)")
            try? FileManager.default.removeItem(at: workingURL)
            completion(makeResult(succeeded: false, error: terminalError ?? "写入器未成功启动"))
            return
        }
        state = .finishing
        let v = appendedVideo, a = appendedAudio, f = failedAppends
        lock.unlock()
        videoInput?.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let completed = self.writer.status == .completed
            self.state = completed ? .done : .failed
            let status = self.writer.status.rawValue
            let error = self.writer.error
            if !completed {
                self.terminalError = error?.localizedDescription ?? "封盘失败（状态 \(status)）"
            }
            self.lock.unlock()
            self.debug?("\(self.name): 封盘 status=\(status) error=\(String(describing: error)) video=\(v) audio=\(a) failed=\(f)")

            var finalizeError: String?
            if completed {
                do {
                    if FileManager.default.fileExists(atPath: self.outputURL.path) {
                        try FileManager.default.removeItem(at: self.outputURL)
                    }
                    try FileManager.default.moveItem(at: self.workingURL, to: self.outputURL)
                } catch {
                    finalizeError = "完成文件重命名失败：\(error.localizedDescription)"
                }
            }
            let succeeded = completed && finalizeError == nil
            completion(self.makeResult(
                succeeded: succeeded,
                error: finalizeError ?? self.terminalError
            ))
        }
    }

    func finish(completion: @escaping () -> Void) {
        finish { _ in completion() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if state == .writing || state == .finishing {
            writer.cancelWriting()
        }
        terminalError = "录制已取消"
        state = .failed
        try? FileManager.default.removeItem(at: workingURL)
    }

    private func noteVideoTimeLocked(_ time: CMTime) {
        if firstVideoTime == nil { firstVideoTime = time }
        lastVideoTime = time
    }

    private func failLocked(_ message: String) {
        terminalError = message
        state = .failed
        debug?("\(name): 写入失败：\(message)")
    }

    private func makeResult(succeeded: Bool, error: String?) -> TrackWriterResult {
        lock.lock()
        let videoFrames = appendedVideo
        let audioSamples = appendedAudio.values.reduce(0, +)
        let failed = failedAppends
        let first = firstVideoTime
        let last = lastVideoTime
        lock.unlock()

        let duration: TimeInterval
        if let first, let last, videoFrames > 1 {
            duration = max(0, CMTimeGetSeconds(CMTimeSubtract(last, first)))
        } else {
            duration = 0
        }
        let effectiveFPS = duration > 0 ? Double(max(0, videoFrames - 1)) / duration : 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let empty = fileSize <= 0 || (videoInput != nil && videoFrames == 0)
        return TrackWriterResult(
            name: name,
            url: outputURL,
            succeeded: succeeded && !empty,
            fileSize: fileSize,
            videoFrames: videoFrames,
            audioSamples: audioSamples,
            failedAppends: failed,
            duration: duration,
            effectiveFrameRate: effectiveFPS,
            errorText: empty && error == nil ? "文件为空或没有视频帧" : error
        )
    }
}
