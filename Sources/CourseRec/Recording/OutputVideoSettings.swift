import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

enum OutputOrientation: String, CaseIterable, Codable, Identifiable {
    case source, landscape, portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "跟随来源"
        case .landscape: return "横屏"
        case .portrait: return "竖屏"
        }
    }

    func apply(to size: CGSize) -> CGSize {
        switch self {
        case .source:
            return size
        case .landscape where size.height > size.width,
             .portrait where size.width > size.height:
            return CGSize(width: size.height, height: size.width)
        default:
            return size
        }
    }
}

enum OutputResolution: String, CaseIterable, Codable, Identifiable {
    case source, uhd2160, qhd1440, fullHD1080, hd720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .source: return "跟随首层来源"
        case .uhd2160: return "3840 × 2160 (4K)"
        case .qhd1440: return "2560 × 1440 (2K)"
        case .fullHD1080: return "1920 × 1080"
        case .hd720: return "1280 × 720"
        }
    }
    func size(source: CGSize) -> CGSize {
        switch self {
        case .source: return CGSize(width: floor(source.width / 2) * 2, height: floor(source.height / 2) * 2)
        case .uhd2160: return CGSize(width: 3840, height: 2160)
        case .qhd1440: return CGSize(width: 2560, height: 1440)
        case .fullHD1080: return CGSize(width: 1920, height: 1080)
        case .hd720: return CGSize(width: 1280, height: 720)
        }
    }
}

enum OutputFrameRate: Int, CaseIterable, Codable, Identifiable {
    case fps15 = 15, fps24 = 24, fps25 = 25, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum OutputCodec: String, CaseIterable, Codable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum OutputBitrate: String, CaseIterable, Codable, Identifiable {
    case automatic, mbps8, mbps12, mbps20, mbps35, mbps60
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "自动"
        case .mbps8: return "8 Mbps"
        case .mbps12: return "12 Mbps"
        case .mbps20: return "20 Mbps"
        case .mbps35: return "35 Mbps"
        case .mbps60: return "60 Mbps"
        }
    }
    func value(size: CGSize, fps: Int, codec: OutputCodec) -> Int {
        let fixed: Int?
        switch self {
        case .automatic: fixed = nil
        case .mbps8: fixed = 8_000_000
        case .mbps12: fixed = 12_000_000
        case .mbps20: fixed = 20_000_000
        case .mbps35: fixed = 35_000_000
        case .mbps60: fixed = 60_000_000
        }
        if let fixed { return fixed }
        let codecFactor = codec == .hevc ? 0.045 : 0.07
        return Int(min(80_000_000, max(4_000_000, size.width * size.height * Double(fps) * codecFactor)))
    }
}

struct OutputVideoSettings: Codable, Equatable {
    var resolution: OutputResolution
    var frameRate: OutputFrameRate
    var codec: OutputCodec
    var bitrate: OutputBitrate
    var orientation: OutputOrientation

    init(
        resolution: OutputResolution,
        frameRate: OutputFrameRate,
        codec: OutputCodec,
        bitrate: OutputBitrate,
        orientation: OutputOrientation = .source
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.bitrate = bitrate
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, codec, bitrate, orientation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try values.decode(OutputResolution.self, forKey: .resolution)
        frameRate = try values.decode(OutputFrameRate.self, forKey: .frameRate)
        codec = try values.decode(OutputCodec.self, forKey: .codec)
        bitrate = try values.decode(OutputBitrate.self, forKey: .bitrate)
        orientation = try values.decodeIfPresent(OutputOrientation.self, forKey: .orientation) ?? .source
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(resolution, forKey: .resolution)
        try values.encode(frameRate, forKey: .frameRate)
        try values.encode(codec, forKey: .codec)
        try values.encode(bitrate, forKey: .bitrate)
        try values.encode(orientation, forKey: .orientation)
    }

    func size(source: CGSize) -> CGSize {
        orientation.apply(to: resolution.size(source: source))
    }

    func sizeLabel(source: CGSize) -> String {
        let output = size(source: source)
        return "\(Int(output.width)) × \(Int(output.height))"
    }

    func hasHardwareEncoder(sourceSize: CGSize) -> Bool {
        let size = size(source: sourceSize)
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    func estimatedBytes(
        duration: TimeInterval,
        sourceSize: CGSize,
        videoSourceCount: Int,
        audioSourceCount: Int
    ) -> Int64 {
        let compositionSize = size(source: sourceSize)
        let compositionRate = bitrate.value(
            size: compositionSize,
            fps: frameRate.rawValue,
            codec: codec
        )
        // ISO 保留原分辨率；预检按成片尺寸估算并额外留 20% 容器/波动余量。
        let videoRate = Int64(compositionRate) * Int64(max(1, videoSourceCount + 1))
        let audioRate = Int64(256_000 * max(1, audioSourceCount + 1))
        return Int64(Double(videoRate + audioRate) / 8 * duration * 1.2)
    }

    func estimateLabel(
        sourceSize: CGSize,
        videoSourceCount: Int,
        audioSourceCount: Int
    ) -> String {
        let size = size(source: sourceSize)
        let rate = bitrate.value(size: size, fps: frameRate.rawValue, codec: codec)
        let total = estimatedBytes(
            duration: 60 * 60,
            sourceSize: sourceSize,
            videoSourceCount: videoSourceCount,
            audioSourceCount: audioSourceCount
        )
        return String(
            format: "当前成片码率约 %.1f Mbps；成片和所有独立文件预计 %@/小时。实际大小随画面复杂度变化。",
            Double(rate) / 1_000_000,
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }
}

enum OutputPreset: String, CaseIterable, Identifiable {
    case compatible
    case highQuality
    case ultraHD
    case portraitCourse

    var id: String { rawValue }
    var label: String {
        switch self {
        case .compatible: return "兼容录制"
        case .highQuality: return "高清课程"
        case .ultraHD: return "4K 高帧率"
        case .portraitCourse: return "竖屏课程"
        }
    }
}
