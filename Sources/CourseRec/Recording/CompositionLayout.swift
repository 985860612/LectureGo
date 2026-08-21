import CoreGraphics
import Foundation

enum CompositionTemplate: String, CaseIterable, Codable, Identifiable {
    case screenOnly
    case cameraOnly
    case screenCameraPip
    case cameraScreenPip
    case presenterSplit
    case equalSplit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenOnly: return "首层全屏"
        case .cameraOnly: return "首层留白"
        case .screenCameraPip: return "右下画中画"
        case .cameraScreenPip: return "左下画中画"
        case .presenterSplit: return "讲解分栏"
        case .equalSplit: return "均分对照"
        }
    }

    var detail: String {
        switch self {
        case .screenOnly: return "第 1 个可见图层铺满画布"
        case .cameraOnly: return "第 1 个可见图层四周留白"
        case .screenCameraPip: return "前两层排列为右下画中画"
        case .cameraScreenPip: return "前两层排列为左下画中画"
        case .presenterSplit: return "前两层按 72% / 28% 分栏"
        case .equalSplit: return "前两个图层各占一半"
        }
    }
}

/// 左上角为原点的归一化矩形，便于在任意输出分辨率和监看尺寸间映射。
struct NormalizedRect: Codable, Equatable, CustomStringConvertible {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultOverlay = NormalizedRect(x: 0.71, y: 0.64, width: 0.27, height: 0.32)
    static let leftOverlay = NormalizedRect(x: 0.02, y: 0.64, width: 0.27, height: 0.32)
    static let fullCanvas = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var description: String {
        String(format: "x=%.3f y=%.3f w=%.3f h=%.3f", x, y, width, height)
    }

    func clamped(minimumSize: Double = 0.08, maximumSize: Double = 1) -> NormalizedRect {
        let safeWidth = min(maximumSize, max(minimumSize, width))
        let safeHeight = min(maximumSize, max(minimumSize, height))
        return NormalizedRect(
            x: min(1 - safeWidth, max(0, x)),
            y: min(1 - safeHeight, max(0, y)),
            width: safeWidth,
            height: safeHeight
        )
    }

    func cgRect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

struct CompositionLayout: Codable, Equatable, CustomStringConvertible {
    var template: CompositionTemplate = .screenCameraPip
    var overlayRect: NormalizedRect = .defaultOverlay
    var fillOverlay = true
    var fillPrimary = false
    /// 可选是为了兼容旧场景 JSON；nil 等同 false。
    var stretchPrimary: Bool?
    /// nil 表示沿用模板默认主画框，兼容旧场景 JSON。
    var primaryRect: NormalizedRect?
    var primaryAnchorX = 0.5
    var primaryAnchorY = 0.5

    var description: String {
        "template=\(template.rawValue) primaryRect=(\(primaryRect ?? .fullCanvas)) overlay=(\(overlayRect)) overlayFill=\(fillOverlay) primaryFill=\(fillPrimary) primaryStretch=\(stretchPrimary == true) primaryAnchor=(\(primaryAnchorX),\(primaryAnchorY))"
    }
}

enum LayerEditorMode {
    case frame
    case crop
}

enum LayerSizePreset: Double, CaseIterable, Identifiable {
    case full = 1
    case half = 0.5
    case quarter = 0.25
    case eighth = 0.125

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .full: return "1"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        }
    }
}

enum LayerPositionPreset: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case center
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .center: return "居中"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }

    func origin(width: Double, height: Double) -> (x: Double, y: Double) {
        switch self {
        case .topLeft: return (0, 0)
        case .topRight: return (1 - width, 0)
        case .center: return ((1 - width) / 2, (1 - height) / 2)
        case .bottomLeft: return (0, 1 - height)
        case .bottomRight: return (1 - width, 1 - height)
        }
    }

    func matches(_ rect: NormalizedRect, tolerance: Double = 0.015) -> Bool {
        let target = origin(width: rect.width, height: rect.height)
        return abs(rect.x - target.x) <= tolerance && abs(rect.y - target.y) <= tolerance
    }

    static func matching(_ rect: NormalizedRect) -> LayerPositionPreset? {
        // 满画布时多个锚点的坐标相同，优先把它显示为“居中”。
        [center, topLeft, topRight, bottomLeft, bottomRight].first { $0.matches(rect) }
    }
}
