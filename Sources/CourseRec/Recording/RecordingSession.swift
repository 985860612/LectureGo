import AVFoundation
import Foundation

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

struct RecordingSessionResult {
    let folderURL: URL
    let files: [TrackWriterResult]
    let errors: [String]
    let warnings: [String]
    let droppedBuffers: Int

    var composedFile: TrackWriterResult? { files.first { $0.name == "成片.mov" } }
    var succeeded: Bool {
        composedFile?.succeeded == true && errors.isEmpty && files.allSatisfy(\.succeeded)
    }

    var statusText: String {
        if succeeded {
            let fps = composedFile?.effectiveFrameRate ?? 0
            let drop = droppedBuffers > 0 ? "，丢弃 \(droppedBuffers) 帧" : ""
            let warning = warnings.isEmpty ? "" : "，有 \(warnings.count) 项警告"
            return fps > 0 ? String(format: "已保存（实际 %.1f fps%@%@）", fps, drop, warning) : "已保存\(drop)\(warning)"
        }
        let reason = errors.first
            ?? files.first(where: { !$0.succeeded })?.errorText
            ?? "成片未生成"
        return "录制失败：\(reason)"
    }
}

struct RecordingHealthSnapshot {
    let effectiveFrameRate: Double
    let droppedBuffers: Int
    let writtenBytes: Int64
    let compositionMilliseconds: Double
    let writerFailed: Bool
    let errorText: String?
}

/// 多源录制会话：每个来源独立落盘，并按有序图层合成为成片。
final class RecordingSession {
    let folderURL: URL
    private(set) var startDate = Date()
    private(set) var droppedBuffers = 0

    private let sources: [RecordingSourceDefinition]
    private let sourceByID: [UUID: RecordingSourceDefinition]
    private let outputSettings: OutputVideoSettings
    private var layers: [CompositionLayer]
    private var driverID: UUID {
        layers.first(where: \.isVisible)?.sourceID
            ?? sources.first(where: { $0.kind.isVideo })?.id
            ?? UUID()
    }
    private let compositor = FrameCompositor()
    private let processingQueue = DispatchQueue(
        label: "courserec.recording.pipeline",
        qos: .userInitiated
    )
    private var t0: CMTime?
    private var videoWriters: [UUID: TrackWriter] = [:]
    private var audioWriters: [RoutedBufferSource: TrackWriter] = [:]
    private var composedWriter: TrackWriter?
    private var composedAudioTrackNames: Set<String> = []
    private var audioFormatHints: [RoutedBufferSource: CMFormatDescription] = [:]
    private var latestVideoFrames: [UUID: CVPixelBuffer] = [:]
    private var latestVideoSamples: [UUID: CMSampleBuffer] = [:]
    private var firstDriverBuffer: CMSampleBuffer?
    private var outputSize: CGSize?
    private var lastComposedTime: CMTime?
    private var lastRenderedFrame: CVPixelBuffer?
    private var transitionFromFrame: CVPixelBuffer?
    private var transitionStartTime: CMTime?
    private var transitionDuration: TimeInterval = 0
    private var averageCompositionMilliseconds = 0.0
    private var markers: [TimeInterval] = []
    private var debugLines: [String] = []
    private var sessionErrors: [String] = []
    private var sessionWarnings: [String] = []
    private let lock = NSLock()

    var markerCount: Int { processingQueue.sync { lock.withLock { markers.count } } }

    var healthSnapshot: RecordingHealthSnapshot {
        processingQueue.sync {
            let writer = composedWriter?.snapshot
            let snapshots = Array(videoWriters.values).map(\.snapshot)
                + Array(audioWriters.values).map(\.snapshot)
                + [writer].compactMap { $0 }
            return RecordingHealthSnapshot(
                effectiveFrameRate: writer?.effectiveFrameRate ?? 0,
                droppedBuffers: lock.withLock { droppedBuffers },
                writtenBytes: snapshots.reduce(0) { $0 + $1.writtenBytes },
                compositionMilliseconds: averageCompositionMilliseconds,
                writerFailed: writer?.state == .failed,
                errorText: writer?.errorText ?? lock.withLock { sessionErrors.first }
            )
        }
    }

    init(
        baseDir: URL,
        sources: [RecordingSourceDefinition],
        layers: [CompositionLayer],
        outputSettings: OutputVideoSettings,
        recordingTitle: String = "课录"
    ) throws {
        self.sources = sources
        sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        self.outputSettings = outputSettings
        self.layers = layers
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeTitle = recordingTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = "\(safeTitle.isEmpty ? "课录" : safeTitle)-\(formatter.string(from: Date()))"
        var candidate = baseDir.appendingPathComponent(stem)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = baseDir.appendingPathComponent("\(stem)-\(suffix)")
            suffix += 1
        }
        folderURL = candidate
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        dlog("多源会话创建 sources=\(sources.count) layers=\(layers.count) output=\(outputSettings.resolution.label) \(outputSettings.frameRate.label) \(outputSettings.codec.label) \(outputSettings.bitrate.label)")
    }

    func updateComposition(
        layers: [CompositionLayer],
        transition: SceneTransition
    ) {
        processingQueue.async { [self] in
            let changed = self.layers != layers
            if changed, transition.duration > 0, let lastRenderedFrame {
                transitionFromFrame = lastRenderedFrame
                transitionStartTime = nil
                transitionDuration = transition.duration
            } else if changed {
                transitionFromFrame = nil
                transitionStartTime = nil
                transitionDuration = 0
            }
            self.layers = layers
            dlog("导播切换 layers=\(layers.count) transition=\(transition.label)")
        }
    }

    func handleBuffer(_ buffer: CMSampleBuffer, source: RoutedBufferSource) {
        let box = SendableSampleBuffer(value: buffer)
        processingQueue.async { [self] in
            processBuffer(box.value, source: source)
        }
    }

    private func processBuffer(_ buffer: CMSampleBuffer, source: RoutedBufferSource) {
        guard buffer.isValid else { return }
        let start = lock.withLock { () -> CMTime in
            if t0 == nil { t0 = CMSampleBufferGetPresentationTimeStamp(buffer) }
            return t0!
        }

        switch source.media {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            latestVideoFrames[source.id] = pixelBuffer
            latestVideoSamples[source.id] = buffer
            appendVideoISO(buffer, sourceID: source.id, t0: start)
            if source.id == driverID {
                if firstDriverBuffer == nil { firstDriverBuffer = buffer }
                let time = CMSampleBufferGetPresentationTimeStamp(buffer)
                ensureComposedWriter(t0: start, currentTime: time)
                appendComposedFrame(at: time, driver: pixelBuffer)
            }
        case .microphoneAudio, .systemAudio:
            if audioFormatHints[source] == nil,
               let format = CMSampleBufferGetFormatDescription(buffer) {
                audioFormatHints[source] = format
            }
            let writer = ensureAudioWriter(source, t0: start)
            if let writer, !writer.appendAudio(buffer, track: "audio") { noteDrop() }
            ensureComposedWriter(
                t0: start,
                currentTime: CMSampleBufferGetPresentationTimeStamp(buffer)
            )
            if let composedWriter {
                let track = audioTrackName(source)
                if composedAudioTrackNames.contains(track),
                   !composedWriter.appendAudio(buffer, track: track) {
                    noteDrop()
                }
            }
        }
    }

    private func appendVideoISO(_ buffer: CMSampleBuffer, sourceID: UUID, t0: CMTime) {
        guard sourceByID[sourceID]?.recordsISO == true else { return }
        let writer: TrackWriter
        if let existing = videoWriters[sourceID] {
            writer = existing
        } else {
            guard let definition = sourceByID[sourceID] else { return }
            let size = Self.pixelSize(of: buffer)
            let url = folderURL.appendingPathComponent("\(sourceIndex(definition))-\(safe(definition.name))-ISO.mov")
            let cgSize = CGSize(width: size.width, height: size.height)
            let created: TrackWriter
            do {
                created = try TrackWriter(
                    url: url,
                    videoSize: size,
                    videoBitRate: outputSettings.bitrate.value(size: cgSize, fps: outputSettings.frameRate.rawValue, codec: outputSettings.codec),
                    videoCodec: outputSettings.codec.avCodec,
                    expectedFrameRate: outputSettings.frameRate.rawValue
                )
            } catch {
                recordError("视频 ISO 创建失败（\(definition.name)）：\(error.localizedDescription)")
                return
            }
            created.debug = { [weak self] in self?.dlog($0) }
            created.startIfNeeded(t0: t0)
            videoWriters[sourceID] = created
            writer = created
        }
        if !writer.appendVideo(buffer) { noteDrop() }
    }

    private func ensureAudioWriter(_ source: RoutedBufferSource, t0: CMTime) -> TrackWriter? {
        if let writer = audioWriters[source] { return writer }
        guard let hint = audioFormatHints[source],
              let definition = sourceByID[source.id],
              definition.recordsISO
        else { return nil }
        let suffix = source.media == .systemAudio ? "系统声" : "人声"
        let url = folderURL.appendingPathComponent("\(sourceIndex(definition))-\(safe(definition.name))-\(suffix).m4a")
        let writer: TrackWriter
        do {
            writer = try TrackWriter(
                url: url,
                audioTracks: ["audio"],
                audioFormatHints: ["audio": hint]
            )
        } catch {
            recordError("音频文件创建失败（\(definition.name)）：\(error.localizedDescription)")
            return nil
        }
        writer.debug = { [weak self] in self?.dlog($0) }
        writer.startIfNeeded(t0: t0)
        audioWriters[source] = writer
        return writer
    }

    private func ensureComposedWriter(t0: CMTime, currentTime: CMTime) {
        guard composedWriter == nil, let firstDriverBuffer else { return }
        let allExpectedAudio = expectedAudioSources
        let unresolvedMobileAudio = allExpectedAudio.filter { source in
            sourceByID[source.id]?.kind == .mobile && audioFormatHints[source] == nil
        }
        if !unresolvedMobileAudio.isEmpty {
            let firstVideoTime = CMSampleBufferGetPresentationTimeStamp(firstDriverBuffer)
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstVideoTime))
            // 手机传来的是压缩 AAC，必须等首包 formatHint 才能创建直通输入。
            // 最多等待 1 秒；若手机没有音频，仍优先保证成片视频正常开始录制。
            guard elapsed.isFinite, elapsed >= 1 else { return }
            recordWarning("移动端音频 1 秒内未就绪，成片暂不包含该音轨（独立音轨仍会继续尝试录制）")
        }
        let expectedAudio = allExpectedAudio.filter { !unresolvedMobileAudio.contains($0) }
        let sourceSize = Self.pixelSize(of: firstDriverBuffer)
        let selectedSize = outputSettings.size(
            source: CGSize(width: sourceSize.width, height: sourceSize.height)
        )
        let size = (width: Int(selectedSize.width), height: Int(selectedSize.height))
        outputSize = selectedSize
        let tracks = expectedAudio.map(audioTrackName)
        let hints = Dictionary(uniqueKeysWithValues: expectedAudio.compactMap { source in
            audioFormatHints[source].map { (audioTrackName(source), $0) }
        })
        let writer: TrackWriter
        do {
            writer = try TrackWriter(
                url: folderURL.appendingPathComponent("成片.mov"),
                videoSize: size,
                videoBitRate: outputSettings.bitrate.value(size: selectedSize, fps: outputSettings.frameRate.rawValue, codec: outputSettings.codec),
                videoCodec: outputSettings.codec.avCodec,
                expectedFrameRate: outputSettings.frameRate.rawValue,
                needsPixelBufferAdaptor: true,
                audioTracks: tracks,
                audioFormatHints: hints
            )
        } catch {
            recordError("成片创建失败：\(error.localizedDescription)")
            return
        }
        writer.debug = { [weak self] in self?.dlog($0) }
        writer.startIfNeeded(t0: t0)
        composedAudioTrackNames = Set(tracks)
        composedWriter = writer
    }

    private func appendComposedFrame(at time: CMTime, driver: CVPixelBuffer) {
        guard let writer = composedWriter, let pool = writer.pixelBufferPool, let outputSize else { return }
        if let lastComposedTime {
            let interval = CMTimeGetSeconds(CMTimeSubtract(time, lastComposedTime))
            if interval < (1.0 / Double(outputSettings.frameRate.rawValue)) * 0.92 { return }
        }
        var compositionFrames = layers.compactMap { layer in
            latestVideoFrames[layer.sourceID].map { (frame: $0, layer: layer) }
        }
        if compositionFrames.isEmpty, let fallbackLayer = layers.first {
            compositionFrames = [(frame: driver, layer: fallbackLayer)]
        }
        let compositionStart = CFAbsoluteTimeGetCurrent()
        guard let newFrame = compositor.render(
            frames: compositionFrames,
            outputSize: outputSize,
            into: pool
        ) else { noteDrop(); return }
        var rendered = newFrame
        if let from = transitionFromFrame, transitionDuration > 0 {
            if transitionStartTime == nil { transitionStartTime = time }
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, transitionStartTime!))
            let progress = max(0, elapsed / transitionDuration)
            if progress >= 1 {
                transitionFromFrame = nil
                transitionStartTime = nil
                transitionDuration = 0
            } else if let blended = compositor.crossfade(
                from: from,
                to: newFrame,
                progress: progress,
                into: pool
            ) {
                rendered = blended
            }
        }
        if !writer.appendPixelBuffer(rendered, at: time) { noteDrop() }
        else {
            lastComposedTime = time
            lastRenderedFrame = rendered
            let milliseconds = (CFAbsoluteTimeGetCurrent() - compositionStart) * 1_000
            averageCompositionMilliseconds = averageCompositionMilliseconds == 0
                ? milliseconds
                : averageCompositionMilliseconds * 0.9 + milliseconds * 0.1
        }
    }

    private var expectedAudioSources: [RoutedBufferSource] {
        sources.flatMap(\.routedAudioSources)
    }

    func addMarker() {
        processingQueue.async { [self] in
            lock.withLock {
                guard let t0 else { return }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                markers.append(CMTimeGetSeconds(CMTimeSubtract(now, t0)))
            }
        }
    }

    func finish(completion: @escaping (RecordingSessionResult) -> Void) {
        processingQueue.async { [self] in
            appendFinalVideoFrames()
            let writers = Array(videoWriters.values) + Array(audioWriters.values) + [composedWriter].compactMap { $0 }
            let group = DispatchGroup()
            let resultLock = NSLock()
            var results: [TrackWriterResult] = []
            writers.forEach { writer in
                group.enter()
                writer.finish { result in
                    resultLock.withLock { results.append(result) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [self] in
                if composedWriter == nil {
                    recordError("没有收到输出图层画面，未能创建成片")
                }
                let missingVideo = sources.filter { $0.kind.isVideo && $0.recordsISO && videoWriters[$0.id] == nil }
                if !missingVideo.isEmpty {
                    recordError("以下视频来源没有生成 ISO：\(missingVideo.map(\.name).joined(separator: "、"))")
                }
                let missingAudio = expectedAudioSources.filter {
                    sourceByID[$0.id]?.recordsISO == true && audioWriters[$0] == nil
                }
                if !missingAudio.isEmpty {
                    recordWarning("\(missingAudio.count) 路音频没有收到有效样本")
                }
                validateFiles(results) { [self] validated in
                    finalize(results: validated, completion: completion)
                }
            }
        }
    }

    /// ScreenCaptureKit 对静止窗口只送“有变化”的帧。封盘前补一张末帧，
    /// 让该来源的 ISO 与整次录制保持同一时间轴，而不是得到几十毫秒的短文件。
    private func appendFinalVideoFrames() {
        guard let driver = latestVideoFrames[driverID] ?? latestVideoFrames.values.first else { return }
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        appendComposedFrame(at: endTime, driver: driver)
        let duration = CMTime(value: 1, timescale: CMTimeScale(outputSettings.frameRate.rawValue))
        for (id, writer) in videoWriters {
            guard let sample = latestVideoSamples[id] else { continue }
            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMTimeCompare(endTime, sampleTime) > 0 else { continue }
            var timing = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: endTime,
                decodeTimeStamp: .invalid
            )
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copy
            )
            if status == noErr, let copy {
                if !writer.appendVideo(copy) { noteDrop() }
            } else {
                recordWarning("\(sourceByID[id]?.name ?? "视频来源") 无法补齐静止末帧")
            }
        }
    }

    private func validateFiles(
        _ files: [TrackWriterResult],
        completion: @escaping ([TrackWriterResult]) -> Void
    ) {
        Task {
            var validated: [TrackWriterResult] = []
            for file in files {
                guard file.succeeded else {
                    validated.append(file)
                    continue
                }
                do {
                    let asset = AVURLAsset(url: file.url)
                    let tracks = try await asset.load(.tracks)
                    let duration = CMTimeGetSeconds(try await asset.load(.duration))
                    guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
                        validated.append(file.validated(
                            succeeded: false,
                            duration: duration.isFinite ? max(0, duration) : 0,
                            errorText: "封盘后校验失败：文件没有有效轨道或时长"
                        ))
                        continue
                    }
                    validated.append(file.validated(
                        succeeded: true,
                        duration: duration,
                        errorText: file.errorText
                    ))
                } catch {
                    validated.append(file.validated(
                        succeeded: false,
                        duration: file.duration,
                        errorText: "封盘后无法读取：\(error.localizedDescription)"
                    ))
                }
            }
            let finalFiles = validated
            await MainActor.run { completion(finalFiles) }
        }
    }

    private func finalize(
        results: [TrackWriterResult],
        completion: @escaping (RecordingSessionResult) -> Void
    ) {
        let complete: ([TrackWriterResult]) -> Void = { [self] finalFiles in
            if let fps = finalFiles.first(where: { $0.name == "成片.mov" })?.effectiveFrameRate,
               fps > 0,
               fps < Double(outputSettings.frameRate.rawValue) * 0.82 {
                recordWarning(String(
                    format: "成片实际 %.1f fps，低于目标 %d fps",
                    fps,
                    outputSettings.frameRate.rawValue
                ))
            }
            Task { @MainActor in
                do {
                    let timeline = try await DavinciTimelineExporter.export(
                        folderURL: folderURL,
                        fileURLs: finalFiles.filter(\.succeeded).map(\.url),
                        frameRate: Double(outputSettings.frameRate.rawValue),
                        markers: lock.withLock { markers }
                    )
                    dlog("达芬奇时间线已生成：\(timeline.xmlURL.lastPathComponent)、\(timeline.otioURL.lastPathComponent)")
                    if !timeline.skippedFiles.isEmpty {
                        recordWarning("达芬奇时间线跳过无效素材：\(timeline.skippedFiles.joined(separator: "、"))")
                    }
                } catch {
                    recordWarning("达芬奇时间线生成失败：\(error.localizedDescription)")
                }
                let result = RecordingSessionResult(
                    folderURL: folderURL,
                    files: finalFiles.sorted { $0.name < $1.name },
                    errors: lock.withLock { sessionErrors },
                    warnings: lock.withLock { sessionWarnings },
                    droppedBuffers: droppedBuffers
                )
                writeSidecars(result: result)
                completion(result)
            }
        }
        guard expectedAudioSources.count > 0,
              results.first(where: { $0.name == "成片.mov" })?.succeeded == true
        else {
            complete(results)
            return
        }
        AudioMixdownExporter.export(
            sourceURL: folderURL.appendingPathComponent("成片.mov"),
            outputURL: folderURL.appendingPathComponent("成片混音.m4a")
        ) { [self] mixResult in
            switch mixResult {
            case let .success(file): complete(results + [file])
            case let .failure(error):
                recordWarning("自动混音失败：\(error.localizedDescription)")
                complete(results)
            }
        }
    }

    func cancelAndRemoveFolder() {
        processingQueue.sync {
            let writers = Array(videoWriters.values) + Array(audioWriters.values) + [composedWriter].compactMap { $0 }
            writers.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: folderURL)
    }

    private func writeSidecars(result: RecordingSessionResult) {
        let markerList = lock.withLock { markers }
        if !markerList.isEmpty {
            let rows = markerList.enumerated().map { "标记 \($0.offset + 1)\t\(Self.formatTime($0.element))" }
            try? ("课录分段标记\n" + rows.joined(separator: "\n")).write(
                to: folderURL.appendingPathComponent("分段标记.txt"), atomically: true, encoding: .utf8
            )
        }
        dlog("会话结束 dropped=\(droppedBuffers)")
        try? debugLines.joined(separator: "\n").write(
            to: folderURL.appendingPathComponent("调试日志.txt"), atomically: true, encoding: .utf8
        )
        let rows = result.files.map { file in
            let state = file.succeeded ? "正常" : "失败"
            let fps = file.effectiveFrameRate > 0 ? String(format: "%.2f", file.effectiveFrameRate) : "-"
            let size = ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
            let detail = file.errorText.map { "；\($0)" } ?? ""
            return "\(state)\t\(file.name)\t\(size)\t\(Self.formatTime(file.duration))\t\(file.videoFrames) 帧\t\(fps) fps\t丢弃 \(file.failedAppends)\(detail)"
        }
        let report = ([
            "课录录制报告",
            "结果：\(result.succeeded ? "成功" : "失败")",
            "输出图层：\(layers.count)",
            "输出：\(outputSettings.resolution.label) / \(outputSettings.frameRate.label) / \(outputSettings.codec.label) / \(outputSettings.bitrate.label)",
            String(format: "Core Image 合成耗时：%.2f ms/帧", averageCompositionMilliseconds),
            "总丢弃：\(result.droppedBuffers)",
            "来源：\(sources.map { "\($0.name)[\($0.kind.label)] \($0.deviceIdentifier)" }.joined(separator: "；"))",
            "",
            "文件："
        ] + rows + [
            "",
            "错误：\(result.errors.isEmpty ? "无" : result.errors.joined(separator: "；"))",
            "警告：\(result.warnings.isEmpty ? "无" : result.warnings.joined(separator: "；"))"
        ]).joined(separator: "\n")
        try? report.write(
            to: folderURL.appendingPathComponent("录制报告.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func audioTrackName(_ source: RoutedBufferSource) -> String { "audio_\(source.id.uuidString.prefix(8))_\(source.media)" }
    private func sourceIndex(_ source: RecordingSourceDefinition) -> String { String(format: "%02d", (sources.firstIndex { $0.id == source.id } ?? 0) + 1) }
    private func safe(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
    private func noteDrop() { lock.withLock { droppedBuffers += 1 } }
    private func recordError(_ text: String) {
        lock.withLock { if !sessionErrors.contains(text) { sessionErrors.append(text) } }
        dlog("错误：\(text)", level: .error)
    }
    private func recordWarning(_ text: String) {
        lock.withLock { if !sessionWarnings.contains(text) { sessionWarnings.append(text) } }
        dlog("警告：\(text)", level: .warning)
    }
    private func dlog(_ text: String, level: DiagnosticLogLevel = .debug) {
        lock.withLock {
            debugLines.append(String(format: "[+%7.3f] %@", Date().timeIntervalSince(startDate), text))
        }
        DiagnosticLogger.shared.log(
            level,
            category: "recording",
            text,
            metadata: ["folder": folderURL.lastPathComponent]
        )
    }
    private static func pixelSize(of buffer: CMSampleBuffer) -> (width: Int, height: Int) {
        guard let pb = CMSampleBufferGetImageBuffer(buffer) else { return (1920, 1080) }
        return (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
    }
    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
