import AVFoundation
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureSourceItem: ObservableObject, Identifiable {
    let id: UUID
    let kind: CaptureSourceKind
    @Published var name: String
    @Published var deviceIdentifier: String
    @Published var frame: CGImage?
    @Published var averageLevel = 0.0
    @Published var peakLevel = 0.0
    @Published var isClipping = false
    @Published var errorText: String?
    @Published var isEnabled: Bool
    @Published var recordsISO: Bool
    @Published var isMuted: Bool
    @Published var videoFormatText = ""
    @Published var observedFrameRate = 0.0
    @Published var gainDB: Double
    var latestPixelBuffer: CVPixelBuffer?

    init(
        id: UUID = UUID(),
        kind: CaptureSourceKind,
        name: String,
        deviceIdentifier: String,
        isEnabled: Bool = true,
        recordsISO: Bool = true,
        isMuted: Bool = false,
        gainDB: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.isEnabled = isEnabled
        self.recordsISO = recordsISO
        self.isMuted = isMuted
        self.gainDB = gainDB
    }
}

struct PersistedCaptureSource: Codable {
    let id: UUID
    let kind: CaptureSourceKind
    let name: String
    let deviceIdentifier: String
    let isEnabled: Bool
    let recordsISO: Bool
    let isMuted: Bool
    let gainDB: Double?
}

final class CameraSourceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    var onBuffer: ((CMSampleBuffer) -> Void)?

    init(id: UUID) {
        queue = DispatchQueue(label: "courserec.camera.\(id.uuidString)")
    }

    func start(
        device: AVCaptureDevice,
        targetSize: CGSize,
        targetFrameRate: Int
    ) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureSourceError.unavailable }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = false
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureSourceError.unavailable }
        session.addOutput(output)
        try configure(
            device: device,
            targetSize: targetSize,
            targetFrameRate: targetFrameRate
        )
        if !session.isRunning { queue.async { self.session.startRunning() } }
    }

    func stop() { if session.isRunning { queue.async { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        onBuffer?(sampleBuffer)
    }

    private func configure(
        device: AVCaptureDevice,
        targetSize: CGSize,
        targetFrameRate: Int
    ) throws {
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions, Double, Double)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0,
                  let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
            else { return nil }
            return (format, dimensions, range.minFrameRate, range.maxFrameRate)
        }
        guard let best = candidates.min(by: { lhs, rhs in
            Self.formatScore(lhs, targetSize: targetSize, targetFPS: targetFrameRate)
                < Self.formatScore(rhs, targetSize: targetSize, targetFPS: targetFrameRate)
        }) else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best.0
        let supportedFPS = min(best.3, max(best.2, Double(targetFrameRate)))
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(supportedFPS.rounded()))))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private static func formatScore(
        _ value: (AVCaptureDevice.Format, CMVideoDimensions, Double, Double),
        targetSize: CGSize,
        targetFPS: Int
    ) -> Double {
        let width = Double(value.1.width)
        let height = Double(value.1.height)
        let sizeDistance = abs(log(max(1, width) / max(1, targetSize.width)))
            + abs(log(max(1, height) / max(1, targetSize.height)))
        let sourceAspect = width / max(1, height)
        let targetAspect = targetSize.width / max(1, targetSize.height)
        let aspectDistance = abs(sourceAspect - targetAspect) * 2
        let fpsPenalty = value.3 >= Double(targetFPS)
            ? 0
            : (Double(targetFPS) - value.3) / Double(max(1, targetFPS)) * 4
        return sizeDistance + aspectDistance + fpsPenalty
    }
}

final class MicrophoneSourceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let router = CameraOutputRouter()
    var onBuffer: ((CMSampleBuffer) -> Void)? { didSet { router.onAudioBuffer = onBuffer } }
    var onLevel: ((Double, Double, Bool) -> Void)? { didSet { router.onAudioLevel = onLevel } }
    var gainDB: Double {
        get { router.gainDB }
        set { router.gainDB = newValue }
    }

    init(id: UUID) {
        queue = DispatchQueue(label: "courserec.microphone.\(id.uuidString)")
    }

    func start(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureSourceError.unavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        output.setSampleBufferDelegate(router, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureSourceError.unavailable }
        session.addOutput(output)
        if !session.isRunning { queue.async { self.session.startRunning() } }
    }

    func stop() { if session.isRunning { queue.async { self.session.stopRunning() } } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}

final class ScreenSourceCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let videoQueue: DispatchQueue
    private let audioQueue: DispatchQueue
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    init(id: UUID) {
        videoQueue = DispatchQueue(label: "courserec.screen.\(id.uuidString)")
        audioQueue = DispatchQueue(label: "courserec.systemaudio.\(id.uuidString)")
    }

    func start(
        display: SCDisplay,
        excludedApplications: [SCRunningApplication],
        recording: Bool,
        capturesAudio: Bool = false,
        frameRate: Int = 30
    ) async throws {
        if let stream { try? await stream.stopCapture() }
        // 来源可能在 App 窗口出现前初始化；每次启流重新枚举，避免首次列表里没有本进程而产生递归画面。
        let currentContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let currentOwnApplications = currentContent.applications.filter {
            $0.processID == ownPID || (ownBundleID != nil && $0.bundleIdentifier == ownBundleID)
        }
        let excludedByPID = Dictionary(
            uniqueKeysWithValues: (excludedApplications + currentOwnApplications).map { ($0.processID, $0) }
        )
        let filter = SCContentFilter(
            display: display,
            excludingApplications: Array(excludedByPID.values),
            exceptingWindows: []
        )
        try await start(
            filter: filter,
            recording: recording,
            capturesAudio: capturesAudio,
            frameRate: frameRate
        )
    }

    func start(
        window: SCWindow,
        recording: Bool,
        capturesAudio: Bool = false,
        frameRate: Int = 30
    ) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await start(
            filter: filter,
            recording: recording,
            capturesAudio: capturesAudio,
            frameRate: frameRate
        )
    }

    private func start(
        filter: SCContentFilter,
        recording: Bool,
        capturesAudio: Bool,
        frameRate: Int
    ) async throws {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(recording ? frameRate : 15))
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = recording && capturesAudio
        if recording && capturesAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        let next = SCStream(filter: filter, configuration: config, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if recording && capturesAudio {
            try next.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await next.startCapture()
        stream = next
    }

    func stop() async {
        if let stream { self.stream = nil; try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            guard Self.isComplete(sampleBuffer) else { return }
            onVideo?(sampleBuffer)
        } else if type == .audio {
            onAudio?(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = list.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

enum CaptureSourceError: LocalizedError {
    case unavailable
    case disconnected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "设备无法加入独立采集会话"
        case let .disconnected(name): return "来源已断开：\(name)"
        }
    }
}
