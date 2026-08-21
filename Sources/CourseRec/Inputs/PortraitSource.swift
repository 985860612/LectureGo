import Foundation

enum MobileSourceKind: String, Hashable, Sendable {
    case screen
    case camera
    case unknown

    var label: String {
        switch self {
        case .screen: return "屏幕"
        case .camera: return "摄像头"
        case .unknown: return "旧版视频"
        }
    }
}

enum PortraitSourceKind: String, CaseIterable, Identifiable {
    case camera
    case mobile
    case rtmp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: return "本机摄像头"
        case .mobile: return "局域网移动端"
        case .rtmp: return "RTMP"
        }
    }
}

struct MobileStreamer: Identifiable, Hashable, Sendable {
    let name: String
    let host: String
    let controlPort: UInt16
    let sourceKind: MobileSourceKind

    var id: String { "\(name)|\(host)|\(controlPort)|\(sourceKind.rawValue)" }
    var label: String { "\(name) · \(sourceKind.label) · \(host)" }

    var sourceIdentifier: String {
        "\(name)\n\(host)\n\(controlPort)\n\(sourceKind.rawValue)"
    }

    init(
        name: String,
        host: String,
        controlPort: UInt16,
        sourceKind: MobileSourceKind = .unknown
    ) {
        self.name = name
        self.host = host
        self.controlPort = controlPort
        self.sourceKind = sourceKind
    }

    init?(sourceIdentifier: String) {
        let parts = sourceIdentifier.split(separator: "\n", omittingEmptySubsequences: false)
        guard (3 ... 4).contains(parts.count),
              let port = UInt16(parts[2]),
              !parts[1].isEmpty
        else { return nil }
        name = String(parts[0])
        host = String(parts[1])
        controlPort = port
        sourceKind = parts.count == 4
            ? MobileSourceKind(rawValue: String(parts[3])) ?? .unknown
            : .unknown
    }
}
