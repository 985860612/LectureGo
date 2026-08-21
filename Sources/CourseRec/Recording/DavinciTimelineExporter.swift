import AVFoundation
import Foundation

/// 把一次录制输出为 DaVinci Resolve 可导入的 OTIO 与 FCP7 XML 时间线。
///
/// OTIO 使用同目录相对路径；XML 使用 Resolve 18.1 可直接定位的绝对文件 URL。
enum DavinciTimelineExporter {
    struct Result {
        let otioURL: URL
        let xmlURL: URL
        let skippedFiles: [String]
    }

    private struct Candidate {
        let url: URL
        let kind: Media.Kind
        let role: String
    }

    struct Media: Equatable {
        enum Kind: String {
            case video = "Video"
            case audio = "Audio"
        }

        let filename: String
        let trackName: String
        let clipName: String
        let kind: Kind
        let duration: TimeInterval
        let enabled: Bool
        let role: String
        let width: Int?
        let height: Int?
        let audioSampleRate: Int?
        let audioChannelCount: Int?

        init(
            filename: String,
            trackName: String,
            clipName: String,
            kind: Kind,
            duration: TimeInterval,
            enabled: Bool,
            role: String,
            width: Int? = nil,
            height: Int? = nil,
            audioSampleRate: Int? = nil,
            audioChannelCount: Int? = nil
        ) {
            self.filename = filename
            self.trackName = trackName
            self.clipName = clipName
            self.kind = kind
            self.duration = duration
            self.enabled = enabled
            self.role = role
            self.width = width
            self.height = height
            self.audioSampleRate = audioSampleRate
            self.audioChannelCount = audioChannelCount
        }
    }

    enum ExportError: LocalizedError {
        case noUsableMedia
        case invalidDuration(String)
        case invalidFrameRate

        var errorDescription: String? {
            switch self {
            case .noUsableMedia:
                return "没有可写入达芬奇时间线的有效素材"
            case let .invalidDuration(filename):
                return "无法读取素材时长：\(filename)"
            case .invalidFrameRate:
                return "达芬奇时间线帧率无效"
            }
        }
    }

    static func export(
        folderURL: URL,
        fileURLs: [URL],
        frameRate: Double,
        markers: [TimeInterval]
    ) async throws -> Result {
        guard frameRate.isFinite, frameRate > 0 else { throw ExportError.invalidFrameRate }
        var media: [Media] = []
        var skippedFiles: [String] = []

        let candidates = timelineCandidates(fileURLs)
        for candidate in candidates {
            let url = candidate.url
            guard FileManager.default.fileExists(atPath: url.path) else {
                skippedFiles.append(url.lastPathComponent)
                continue
            }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else {
                    throw ExportError.invalidDuration(url.lastPathComponent)
                }
                let characteristics = try await mediaCharacteristics(
                    asset: asset,
                    kind: candidate.kind
                )
                let name = url.deletingPathExtension().lastPathComponent
                let trackIndex = media.filter { $0.kind == candidate.kind }.count + 1
                let isMixdown = url.lastPathComponent == "成片混音.m4a"
                let hasUsableVideo = media.contains { $0.kind == .video }
                let hasUsableIsolatedAudio = media.contains {
                    $0.kind == .audio && $0.filename != "成片混音.m4a"
                }
                media.append(Media(
                    filename: url.lastPathComponent,
                    trackName: "\(candidate.kind == .video ? "V" : "A")\(trackIndex) \(name)",
                    clipName: name,
                    kind: candidate.kind,
                    duration: duration,
                    enabled: candidate.kind == .video
                        ? !hasUsableVideo
                        : (!isMixdown || !hasUsableIsolatedAudio),
                    role: candidate.role,
                    width: characteristics.width,
                    height: characteristics.height,
                    audioSampleRate: characteristics.audioSampleRate,
                    audioChannelCount: characteristics.audioChannelCount
                ))
            } catch {
                skippedFiles.append(url.lastPathComponent)
            }
        }

        guard !media.isEmpty else { throw ExportError.noUsableMedia }
        let otioData = try makeDocument(
            name: folderURL.lastPathComponent,
            media: media,
            frameRate: frameRate,
            markers: markers
        )
        let xmlData = try makeLegacyXMLDocument(
            name: folderURL.lastPathComponent,
            folderURL: folderURL,
            media: media,
            frameRate: frameRate,
            markers: markers
        )
        let otioURL = folderURL.appendingPathComponent("课录.otio")
        let xmlURL = folderURL.appendingPathComponent("课录.xml")
        try xmlData.write(to: xmlURL, options: .atomic)
        try otioData.write(to: otioURL, options: .atomic)
        return Result(otioURL: otioURL, xmlURL: xmlURL, skippedFiles: skippedFiles)
    }

    /// 与媒体探测分离，便于在不创建真实音视频文件的情况下验证 OTIO 结构。
    static func makeDocument(
        name: String,
        media: [Media],
        frameRate: Double,
        markers: [TimeInterval]
    ) throws -> Data {
        guard !media.isEmpty else { throw ExportError.noUsableMedia }
        guard frameRate.isFinite, frameRate > 0 else { throw ExportError.invalidFrameRate }

        let tracks = media.map { makeTrack($0, frameRate: frameRate) }
        let timelineMarkers = markers.enumerated().map { index, seconds in
            makeMarker(name: "标记 \(index + 1)", seconds: seconds, frameRate: frameRate)
        }
        let document: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1",
            "metadata": [
                "course_recorder": [
                    "frame_rate": frameRate,
                    "generator": "课录"
                ]
            ],
            "name": name,
            "global_start_time": NSNull(),
            "tracks": [
                "OTIO_SCHEMA": "Stack.1",
                "metadata": [:],
                "name": "课录轨道",
                "source_range": NSNull(),
                "effects": [],
                "markers": timelineMarkers,
                "enabled": true,
                "children": tracks
            ]
        ]

        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Final Cut Pro 7 XML v5，供 DaVinci Resolve 18.1–18.4 导入。
    static func makeLegacyXMLDocument(
        name: String,
        folderURL: URL,
        media: [Media],
        frameRate: Double,
        markers: [TimeInterval]
    ) throws -> Data {
        guard !media.isEmpty else { throw ExportError.noUsableMedia }
        guard frameRate.isFinite, frameRate > 0 else { throw ExportError.invalidFrameRate }

        let sequenceDuration = media.map { frameCount($0, frameRate: frameRate) }.max() ?? 1
        let videoTracks = media.enumerated().compactMap { index, item -> String? in
            guard item.kind == .video else { return nil }
            return makeLegacyXMLTrack(
                media: item,
                folderURL: folderURL,
                identifier: "video-\(index + 1)",
                frameRate: frameRate
            )
        }.joined(separator: "\n")
        let audioTracks = media.enumerated().compactMap { index, item -> String? in
            guard item.kind == .audio else { return nil }
            return makeLegacyXMLTrack(
                media: item,
                folderURL: folderURL,
                identifier: "audio-\(index + 1)",
                frameRate: frameRate
            )
        }.joined(separator: "\n")
        let markerXML = markers.enumerated().map { index, seconds in
            let frame = max(0, Int((seconds * frameRate).rounded()))
            let start = min(frame, max(0, sequenceDuration - 1))
            return """
                <marker>
                    <name>\(xmlEscaped("标记 \(index + 1)"))</name>
                    <in>\(start)</in>
                    <out>\(start + 1)</out>
                </marker>
            """
        }.joined(separator: "\n")

        let firstVideo = media.first { $0.kind == .video }
        let sequenceWidth = firstVideo?.width ?? 1920
        let sequenceHeight = firstVideo?.height ?? 1080
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="5">
            <sequence>
                <name>\(xmlEscaped(name))</name>
                <duration>\(sequenceDuration)</duration>
                \(legacyXMLRate(frameRate))
                <in>-1</in>
                <out>-1</out>
                <timecode>
                    <string>00:00:00:00</string>
                    <frame>0</frame>
                    <displayformat>NDF</displayformat>
                    \(legacyXMLRate(frameRate))
                </timecode>
        \(markerXML)
                <media>
                    <video>
        \(videoTracks)
                        <format>
                            <samplecharacteristics>
                                <width>\(sequenceWidth)</width>
                                <height>\(sequenceHeight)</height>
                                <pixelaspectratio>square</pixelaspectratio>
                                \(legacyXMLRate(frameRate))
                            </samplecharacteristics>
                        </format>
                    </video>
                    <audio>
        \(audioTracks)
                    </audio>
                </media>
            </sequence>
        </xmeml>

        """
        guard let data = xml.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    private static func makeTrack(_ media: Media, frameRate: Double) -> [String: Any] {
        [
            "OTIO_SCHEMA": "Track.1",
            "metadata": [:],
            "name": media.trackName,
            "source_range": NSNull(),
            "effects": [],
            "markers": [],
            "enabled": true,
            "children": [makeClip(media, frameRate: frameRate)],
            "kind": media.kind.rawValue
        ]
    }

    private static func makeClip(_ media: Media, frameRate: Double) -> [String: Any] {
        let range = makeTimeRange(duration: media.duration, frameRate: frameRate)
        return [
            "OTIO_SCHEMA": "Clip.1",
            "metadata": [
                "course_recorder": ["role": media.role]
            ],
            "name": media.clipName,
            "source_range": range,
            "effects": [],
            "markers": [],
            "enabled": media.enabled,
            "media_reference": [
                "OTIO_SCHEMA": "ExternalReference.1",
                "metadata": [:],
                "name": media.filename,
                "available_range": range,
                "target_url": media.filename
            ]
        ]
    }

    private static func makeMarker(
        name: String,
        seconds: TimeInterval,
        frameRate: Double
    ) -> [String: Any] {
        let frame = max(0, (seconds * frameRate).rounded())
        return [
            "OTIO_SCHEMA": "Marker.2",
            "metadata": [:],
            "name": name,
            "color": "RED",
            "marked_range": [
                "OTIO_SCHEMA": "TimeRange.1",
                "start_time": makeRationalTime(value: frame, frameRate: frameRate),
                "duration": makeRationalTime(value: 0, frameRate: frameRate)
            ]
        ]
    }

    private static func makeTimeRange(
        duration: TimeInterval,
        frameRate: Double
    ) -> [String: Any] {
        [
            "OTIO_SCHEMA": "TimeRange.1",
            "start_time": makeRationalTime(value: 0, frameRate: frameRate),
            "duration": makeRationalTime(
                value: ceil(duration * frameRate),
                frameRate: frameRate
            )
        ]
    }

    private static func makeRationalTime(
        value: Double,
        frameRate: Double
    ) -> [String: Any] {
        [
            "OTIO_SCHEMA": "RationalTime.1",
            "rate": frameRate,
            "value": value
        ]
    }

    private static func makeLegacyXMLTrack(
        media: Media,
        folderURL: URL,
        identifier: String,
        frameRate: Double
    ) -> String {
        let frames = frameCount(media, frameRate: frameRate)
        let mediaType = media.kind == .video ? "video" : "audio"
        let path = folderURL.appendingPathComponent(media.filename).absoluteString
        let fileMedia: String
        switch media.kind {
        case .video:
            let width = media.width ?? 1920
            let height = media.height ?? 1080
            fileMedia = """
            <video>
                <duration>\(frames)</duration>
                <samplecharacteristics>
                    <width>\(width)</width>
                    <height>\(height)</height>
                </samplecharacteristics>
            </video>
            """
        case .audio:
            let sampleRate = media.audioSampleRate ?? 48_000
            let channelCount = media.audioChannelCount ?? 2
            fileMedia = """
            <audio>
                <samplecharacteristics>
                    <depth>16</depth>
                    <samplerate>\(sampleRate)</samplerate>
                </samplecharacteristics>
                <channelcount>\(channelCount)</channelcount>
                <duration>\(frames)</duration>
            </audio>
            """
        }

        return """
                        <track>
                            <clipitem id="clip-\(identifier)">
                                <name>\(xmlEscaped(media.clipName))</name>
                                <duration>\(frames)</duration>
                                \(legacyXMLRate(frameRate))
                                <start>0</start>
                                <end>\(frames)</end>
                                <enabled>\(media.enabled ? "TRUE" : "FALSE")</enabled>
                                <in>0</in>
                                <out>\(frames)</out>
                                <file id="file-\(identifier)">
                                    <duration>\(frames)</duration>
                                    \(legacyXMLRate(frameRate))
                                    <name>\(xmlEscaped(media.filename))</name>
                                    <pathurl>\(xmlEscaped(path))</pathurl>
                                    <timecode>
                                        <string>00:00:00:00</string>
                                        <displayformat>NDF</displayformat>
                                        \(legacyXMLRate(frameRate))
                                    </timecode>
                                    <media>\(fileMedia)</media>
                                </file>
                                <sourcetrack>
                                    <mediatype>\(mediaType)</mediatype>
                                    <trackindex>1</trackindex>
                                </sourcetrack>
                                <comments/>
                            </clipitem>
                            <enabled>\(media.enabled ? "TRUE" : "FALSE")</enabled>
                            <locked>FALSE</locked>
                        </track>
        """
    }

    private static func legacyXMLRate(_ frameRate: Double) -> String {
        """
        <rate>
            <timebase>\(Int(frameRate.rounded()))</timebase>
            <ntsc>FALSE</ntsc>
        </rate>
        """
    }

    private static func frameCount(_ media: Media, frameRate: Double) -> Int {
        max(1, Int(ceil(media.duration * frameRate)))
    }

    private static func timelineCandidates(_ fileURLs: [URL]) -> [Candidate] {
        let unique = Dictionary(
            fileURLs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values
        let videos = unique.filter { $0.pathExtension.lowercased() == "mov" }.sorted(by: fileOrder)
        let composed = videos.first { $0.lastPathComponent == "成片.mov" }
        let orderedVideos = [composed].compactMap { $0 } + videos.filter { $0 != composed }
        let videoCandidates = orderedVideos.map { url in
            Candidate(
                url: url,
                kind: .video,
                role: url == composed ? "composed_reference" : "video_iso"
            )
        }

        let audio = unique.filter { $0.pathExtension.lowercased() == "m4a" }.sorted { lhs, rhs in
            let lhsMixdown = lhs.lastPathComponent == "成片混音.m4a"
            let rhsMixdown = rhs.lastPathComponent == "成片混音.m4a"
            if lhsMixdown != rhsMixdown { return !lhsMixdown }
            return fileOrder(lhs, rhs)
        }
        let audioCandidates = audio.map { url in
            Candidate(
                url: url,
                kind: .audio,
                role: url.lastPathComponent == "成片混音.m4a"
                    ? "mixdown_reference"
                    : "isolated_audio"
            )
        }
        return videoCandidates + audioCandidates
    }

    private static func fileOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private struct Characteristics {
        var width: Int?
        var height: Int?
        var audioSampleRate: Int?
        var audioChannelCount: Int?
    }

    private static func mediaCharacteristics(
        asset: AVURLAsset,
        kind: Media.Kind
    ) async throws -> Characteristics {
        switch kind {
        case .video:
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return Characteristics()
            }
            let size = try await track.load(.naturalSize)
            return Characteristics(
                width: max(1, Int(abs(size.width).rounded())),
                height: max(1, Int(abs(size.height).rounded()))
            )
        case .audio:
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let description = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else {
                return Characteristics()
            }
            return Characteristics(
                audioSampleRate: Int(asbd.pointee.mSampleRate.rounded()),
                audioChannelCount: Int(asbd.pointee.mChannelsPerFrame)
            )
        }
    }
}
