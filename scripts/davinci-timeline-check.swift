import Foundation

@main
struct DavinciTimelineCheck {
    enum CheckError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): return message
            }
        }
    }

    static func main() async throws {
        let media: [DavinciTimelineExporter.Media] = [
            .init(
                filename: "屏幕ISO.mov", trackName: "V1 屏幕", clipName: "屏幕ISO",
                kind: .video, duration: 10.01, enabled: true, role: "screen",
                width: 2560, height: 1440
            ),
            .init(
                filename: "人像ISO.mov", trackName: "V2 人像", clipName: "人像ISO",
                kind: .video, duration: 10, enabled: false, role: "portrait",
                width: 1920, height: 1080
            ),
            .init(
                filename: "人声.m4a", trackName: "A1 人声", clipName: "人声",
                kind: .audio, duration: 9.9, enabled: true, role: "voice",
                audioSampleRate: 48_000, audioChannelCount: 2
            )
        ]

        let data = try DavinciTimelineExporter.makeDocument(
            name: "课录-20260820-120000",
            media: media,
            frameRate: 24,
            markers: [1.5, 3]
        )
        let root = try require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "顶层不是 JSON 对象"
        )

        try expect(root["OTIO_SCHEMA"] as? String == "Timeline.1", "时间线 schema 错误")
        try expect(root["name"] as? String == "课录-20260820-120000", "时间线名称错误")

        let stack = try require(root["tracks"] as? [String: Any], "缺少轨道 Stack")
        let tracks = try require(stack["children"] as? [[String: Any]], "缺少轨道列表")
        try expect(tracks.count == 3, "轨道数量错误")
        try expect(
            tracks.compactMap { $0["name"] as? String } == ["V1 屏幕", "V2 人像", "A1 人声"],
            "轨道名称或顺序错误"
        )
        try expect(
            tracks.compactMap { $0["kind"] as? String } == ["Video", "Video", "Audio"],
            "轨道类型错误"
        )

        let screenClip = try firstClip(in: tracks[0])
        let portraitClip = try firstClip(in: tracks[1])
        try expect(screenClip["enabled"] as? Bool == true, "屏幕轨道应启用")
        try expect(portraitClip["enabled"] as? Bool == false, "人像轨道应默认禁用")

        let reference = try require(
            screenClip["media_reference"] as? [String: Any],
            "屏幕素材缺少媒体引用"
        )
        try expect(
            reference["OTIO_SCHEMA"] as? String == "ExternalReference.1",
            "媒体引用 schema 错误"
        )
        try expect(reference["target_url"] as? String == "屏幕ISO.mov", "素材应使用相对路径")

        let sourceRange = try require(
            screenClip["source_range"] as? [String: Any],
            "屏幕素材缺少时间范围"
        )
        let duration = try require(
            sourceRange["duration"] as? [String: Any],
            "屏幕素材缺少时长"
        )
        try expect(duration["rate"] as? Double == 24, "时间基应跟随 24 fps 输出设置")
        try expect(duration["value"] as? Double == 241, "素材时长应向上取整到完整帧")

        let markers = try require(stack["markers"] as? [[String: Any]], "缺少时间线标记")
        try expect(markers.count == 2, "标记数量错误")
        try expect(
            markers.compactMap { $0["name"] as? String } == ["标记 1", "标记 2"],
            "标记名称错误"
        )
        let firstRange = try require(
            markers[0]["marked_range"] as? [String: Any],
            "标记缺少时间范围"
        )
        let firstStart = try require(
            firstRange["start_time"] as? [String: Any],
            "标记缺少开始时间"
        )
        try expect(firstStart["value"] as? Double == 36, "24 fps 下 1.5 秒标记应位于第 36 帧")

        let xmlData = try DavinciTimelineExporter.makeLegacyXMLDocument(
            name: "课录 & 测试",
            folderURL: URL(fileURLWithPath: "/tmp/课录 & 测试"),
            media: media,
            frameRate: 24,
            markers: [1.5, 3]
        )
        let xml = try XMLDocument(data: xmlData)
        let sequence = try require(
            try xml.nodes(forXPath: "/xmeml/sequence").first as? XMLElement,
            "XML 缺少 sequence"
        )
        try expect(
            sequence.elements(forName: "name").first?.stringValue == "课录 & 测试",
            "XML 特殊字符转义错误"
        )
        let xmlVideoTracks = try xml.nodes(forXPath: "/xmeml/sequence/media/video/track")
        let xmlAudioTracks = try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track")
        let xmlMarkers = try xml.nodes(forXPath: "/xmeml/sequence/marker")
        try expect(xmlVideoTracks.count == 2, "XML 视频轨道数量错误")
        try expect(xmlAudioTracks.count == 1, "XML 音频轨道数量错误")
        try expect(xmlMarkers.count == 2, "XML 标记数量错误")
        let sequenceWidth = try require(
            try xml.nodes(forXPath: "/xmeml/sequence/media/video/format/samplecharacteristics/width").first,
            "XML 缺少 sequence 视频尺寸"
        )
        try expect(sequenceWidth.stringValue == "2560", "XML sequence 视频尺寸错误")
        let xmlTimebase = try require(
            try xml.nodes(forXPath: "/xmeml/sequence/rate/timebase").first,
            "XML 缺少 sequence 帧率"
        )
        try expect(xmlTimebase.stringValue == "24", "XML 时间基应跟随 24 fps 输出设置")
        let pathNode = try require(
            try xml.nodes(forXPath: "//clipitem[@id='clip-video-1']/file/pathurl").first,
            "XML 视频素材缺少 pathurl"
        )
        try expect(
            pathNode.stringValue?.hasSuffix("/%E5%B1%8F%E5%B9%95ISO.mov") == true,
            "XML 素材路径错误"
        )

        do {
            _ = try DavinciTimelineExporter.makeDocument(
                name: "空",
                media: [],
                frameRate: 30,
                markers: []
            )
            throw CheckError.failed("空时间线没有被拒绝")
        } catch DavinciTimelineExporter.ExportError.noUsableMedia {
            // Expected.
        }

        if CommandLine.arguments.count == 2 {
            let folderURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            )
            let result = try await DavinciTimelineExporter.export(
                folderURL: folderURL,
                fileURLs: files,
                frameRate: 30,
                markers: [0.1]
            )
            try expect(
                FileManager.default.fileExists(atPath: result.xmlURL.path),
                "实际媒体探测后未生成 XML"
            )
            try expect(
                FileManager.default.fileExists(atPath: result.otioURL.path),
                "实际媒体探测后未生成 OTIO"
            )
            let exportedRoot = try require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: result.otioURL)
                ) as? [String: Any],
                "实际 OTIO 不是 JSON 对象"
            )
            let exportedStack = try require(
                exportedRoot["tracks"] as? [String: Any],
                "实际 OTIO 缺少轨道 Stack"
            )
            let exportedTracks = try require(
                exportedStack["children"] as? [[String: Any]],
                "实际 OTIO 缺少轨道"
            )
            try expect(exportedTracks.count == 6, "动态素材应生成 3V/3A 轨道")
            let videoClips = try exportedTracks.prefix(3).map { try firstClip(in: $0) }
            try expect(videoClips[0]["name"] as? String == "成片", "V1 应为成片参考")
            try expect(videoClips[0]["enabled"] as? Bool == true, "成片参考应默认启用")
            try expect(videoClips.dropFirst().allSatisfy { $0["enabled"] as? Bool == false }, "ISO 视频应默认禁用")
            let audioClips = try exportedTracks.suffix(3).map { try firstClip(in: $0) }
            try expect(audioClips.dropLast().allSatisfy { $0["enabled"] as? Bool == true }, "独立音频应默认启用")
            try expect(audioClips.last?["name"] as? String == "成片混音", "混音参考应位于最后一轨")
            try expect(audioClips.last?["enabled"] as? Bool == false, "存在独立音频时混音参考应默认禁用")
        }

        print("PASS: DaVinci OTIO and Resolve 18 XML timeline structures")
    }

    private static func firstClip(in track: [String: Any]) throws -> [String: Any] {
        let children = try require(track["children"] as? [[String: Any]], "轨道缺少片段")
        return try require(children.first, "轨道片段为空")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckError.failed(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError.failed(message) }
    }
}
