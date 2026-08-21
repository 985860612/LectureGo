import Foundation

enum CaptureSourceKind: String, CaseIterable, Codable {
    case screen
    case window
    case camera
    case mobile
    case rtmp
    case microphone

    var label: String {
        switch self {
        case .screen: return "屏幕"
        case .window: return "窗口"
        case .camera: return "摄像头"
        case .mobile: return "移动端"
        case .rtmp: return "RTMP"
        case .microphone: return "麦克风"
        }
    }

    var isVideo: Bool { self != .microphone }
}

enum RecordingMobileAudioRole {
    case none
    case system
    case microphone
}

struct RecordingSourceDefinition {
    let id: UUID
    let kind: CaptureSourceKind
    let name: String
    let deviceIdentifier: String
    let recordsISO: Bool
    let isMuted: Bool
    let capturesSystemAudio: Bool
    let mobileAudioRole: RecordingMobileAudioRole

    init(
        id: UUID,
        kind: CaptureSourceKind,
        name: String,
        deviceIdentifier: String,
        recordsISO: Bool,
        isMuted: Bool,
        capturesSystemAudio: Bool,
        mobileAudioRole: RecordingMobileAudioRole = .none
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.recordsISO = recordsISO
        self.isMuted = isMuted
        self.capturesSystemAudio = capturesSystemAudio
        self.mobileAudioRole = mobileAudioRole
    }

    var routedAudioSources: [RoutedBufferSource] {
        guard !isMuted else { return [] }
        switch kind {
        case .microphone:
            return [RoutedBufferSource(id: id, media: .microphoneAudio)]
        case .screen, .window:
            return capturesSystemAudio
                ? [RoutedBufferSource(id: id, media: .systemAudio)]
                : []
        case .mobile:
            switch mobileAudioRole {
            case .microphone:
                return [RoutedBufferSource(id: id, media: .microphoneAudio)]
            case .system:
                return capturesSystemAudio
                    ? [RoutedBufferSource(id: id, media: .systemAudio)]
                    : []
            case .none:
                return []
            }
        case .camera, .rtmp:
            return []
        }
    }
}

struct RoutedBufferSource: Hashable {
    enum Media: Hashable {
        case video
        case microphoneAudio
        case systemAudio
    }

    let id: UUID
    let media: Media
}
