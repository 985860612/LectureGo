import AVFoundation
import CoreImage
import Darwin
import ScreenCaptureKit
import SwiftUI
import VideoToolbox

private struct SendablePixelBuffer: @unchecked Sendable { let value: CVPixelBuffer }

@MainActor
final class CaptureManager: ObservableObject {
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var mobileStreamers: [MobileStreamer] = []
    @Published private(set) var sources: [CaptureSourceItem] = []
    @Published private(set) var compositionLayers: [CompositionLayer] = []
    @Published var selectedCompositionLayerID: UUID?
    @Published var selectedLayerEditorMode: LayerEditorMode = .frame
    @Published private(set) var savedScenes: [CompositionScene] = []
    @Published private(set) var activeSceneID: UUID?
    @Published private(set) var sceneHasUnsavedChanges = false
    @Published private(set) var soloAudioSourceID: UUID?
    @Published private(set) var monitoredAudioSourceID: UUID?
    @Published private(set) var composedFrame: CGImage?
    @Published private(set) var outputResolutionText = "等待视频源"
    @Published private(set) var statusText = "正在初始化…"
    @Published private(set) var cameraPermissionGranted = false
    @Published private(set) var micPermissionGranted = false
    @Published private(set) var screenPermissionGranted = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var lastRecordingFolder: URL?
    @Published private(set) var lastRecordingResult: RecordingSessionResult?
    @Published private(set) var markerCount = 0
    @Published private(set) var recordingHealthText = ""
    @Published private(set) var recordingHealthIsWarning = false
    @Published private(set) var recoverablePartialFiles: [URL] = []
    @Published private(set) var localRTMPPublishURL = "正在获取局域网地址…"
    @Published private(set) var localRTMPStreamName = ""
    @Published private(set) var localRTMPStatusText = "正在启动接收服务…"
    @Published private(set) var localRTMPIsReady = false
    @Published private(set) var localRTMPIsPublishing = false
    @Published private(set) var localRTMPHasLANAddress = false

    private var cameraCaptures: [UUID: CameraSourceCapture] = [:]
    private var microphoneCaptures: [UUID: MicrophoneSourceCapture] = [:]
    private var screenCaptures: [UUID: ScreenSourceCapture] = [:]
    private var mobileCaptures: [UUID: MobileInputClient] = [:]
    private var rtmpCaptures: [UUID: RTMPInputClient] = [:]
    private let mobileDiscovery = MobileDiscovery()
    private let localRTMPReceiver = LocalRTMPReceiver()
    private var managedLocalRTMPSourceID: UUID?
    private var recordingSession: RecordingSession?
    private var excludedApplications: [SCRunningApplication] = []
    private var elapsedTask: Task<Void, Never>?
    private var sceneAutosaveTask: Task<Void, Never>?
    private let sourcePreviewQueue = DispatchQueue(label: "courserec.source.preview", qos: .userInteractive)
    private let programPreviewQueue = DispatchQueue(label: "courserec.program.preview", qos: .userInteractive)
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewCompositor = FrameCompositor()
    private let audioMonitor = AudioSourceMonitor()
    private var lastSourcePreview: [UUID: Date] = [:]
    private var sourcePreviewPending: Set<UUID> = []
    private var lastProgramPreview = Date.distantPast
    private var programPreviewPending = false
    private var clipHold: [UUID: Date] = [:]
    private var lastVideoTimestamp: [UUID: CMTime] = [:]
    private var measuredFrameRate: [UUID: Double] = [:]
    private var lastVideoFormatPublish: [UUID: Date] = [:]
    private var lastHealthSampleDate = Date()
    private var lastHealthCPUTime = 0.0
    private var lastHealthWrittenBytes: Int64 = 0

    @AppStorage("compositionTemplate") private var templateRaw = CompositionTemplate.screenCameraPip.rawValue
    @AppStorage("compositionOverlayX") private var overlayX = NormalizedRect.defaultOverlay.x
    @AppStorage("compositionOverlayY") private var overlayY = NormalizedRect.defaultOverlay.y
    @AppStorage("compositionOverlayWidth") private var overlayWidth = NormalizedRect.defaultOverlay.width
    @AppStorage("compositionOverlayHeight") private var overlayHeight = NormalizedRect.defaultOverlay.height
    @AppStorage("compositionFillOverlay") private var overlayFill = true
    @AppStorage("compositionFillPrimary") private var primaryFill = false
    @AppStorage("compositionStretchPrimary") private var primaryStretch = false
    @AppStorage("compositionPrimaryAnchorX") private var primaryAnchorX = 0.5
    @AppStorage("compositionPrimaryAnchorY") private var primaryAnchorY = 0.5
    @AppStorage("compositionPrimaryX") private var primaryX = NormalizedRect.fullCanvas.x
    @AppStorage("compositionPrimaryY") private var primaryY = NormalizedRect.fullCanvas.y
    @AppStorage("compositionPrimaryWidth") private var primaryWidth = NormalizedRect.fullCanvas.width
    @AppStorage("compositionPrimaryHeight") private var primaryHeight = NormalizedRect.fullCanvas.height
    @AppStorage("outputResolution") private var outputResolutionRaw = OutputResolution.source.rawValue
    @AppStorage("outputOrientation") private var outputOrientationRaw = OutputOrientation.source.rawValue
    @AppStorage("outputFrameRate") private var outputFrameRateRaw = OutputFrameRate.fps30.rawValue
    @AppStorage("outputCodec") private var outputCodecRaw = OutputCodec.h264.rawValue
    @AppStorage("outputBitrate") private var outputBitrateRaw = OutputBitrate.automatic.rawValue
    @AppStorage("compositionTemplateSemanticsVersion") private var templateSemanticsVersion = 1
    @AppStorage("captureSourcesJSON") private var captureSourcesJSON = ""
    @AppStorage("primarySourceUUID") private var persistedPrimarySourceID = ""
    @AppStorage("secondarySourceUUID") private var persistedSecondarySourceID = ""
    @AppStorage("compositionLayersJSON") private var compositionLayersJSON = ""
    @AppStorage("compositionGraphVersion") private var compositionGraphVersion = 1
    @AppStorage("compositionScenesJSON") private var compositionScenesJSON = ""
    @AppStorage("activeSceneUUID") private var persistedActiveSceneID = ""
    @AppStorage("activeSceneDirty") private var persistedSceneDirty = false
    @AppStorage("sceneTransition") private var sceneTransitionRaw = SceneTransition.fade300.rawValue
    @AppStorage("soloAudioSourceUUID") private var persistedSoloAudioSourceID = ""
    @AppStorage("recordingTitle") private var storedRecordingTitle = "课录"
    @AppStorage("outputBaseDirectory") private var storedOutputBaseDirectory = ""
    @AppStorage("localRTMPSourceUUID") private var persistedLocalRTMPSourceID = ""

    var selectedTemplate: CompositionTemplate { CompositionTemplate(rawValue: templateRaw) ?? .screenCameraPip }
    var selectedTransition: SceneTransition { SceneTransition(rawValue: sceneTransitionRaw) ?? .fade300 }
    var activeSceneName: String {
        guard let activeSceneID,
              let scene = savedScenes.first(where: { $0.id == activeSceneID })
        else { return "未保存场景" }
        return scene.name
    }

    func isTemplateApplied(_ template: CompositionTemplate) -> Bool {
        let layers = compositionLayers.filter(\.isVisible)
        guard let first = layers.first else { return false }

        func matches(_ actual: NormalizedRect, _ expected: NormalizedRect) -> Bool {
            let tolerance = 0.005
            return abs(actual.x - expected.x) <= tolerance
                && abs(actual.y - expected.y) <= tolerance
                && abs(actual.width - expected.width) <= tolerance
                && abs(actual.height - expected.height) <= tolerance
        }

        switch template {
        case .screenOnly:
            return matches(first.rect, .fullCanvas) && first.displayMode == .fit
        case .cameraOnly:
            return matches(first.rect, NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84))
                && first.displayMode == .fit
        case .screenCameraPip, .cameraScreenPip:
            guard layers.count > 1 else { return false }
            let overlay = template == .screenCameraPip ? NormalizedRect.defaultOverlay : .leftOverlay
            return matches(first.rect, .fullCanvas)
                && first.displayMode == .fit
                && matches(layers[1].rect, overlay)
                && layers[1].displayMode == .fill
        case .presenterSplit:
            guard layers.count > 1 else { return false }
            return matches(first.rect, NormalizedRect(x: 0, y: 0, width: 0.72, height: 1))
                && first.displayMode == .fit
                && matches(layers[1].rect, NormalizedRect(x: 0.72, y: 0, width: 0.28, height: 1))
                && layers[1].displayMode == .fill
        case .equalSplit:
            guard layers.count > 1 else { return false }
            return matches(first.rect, NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
                && first.displayMode == .fill
                && matches(layers[1].rect, NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))
                && layers[1].displayMode == .fill
        }
    }
    var outputSettings: OutputVideoSettings {
        OutputVideoSettings(
            resolution: OutputResolution(rawValue: outputResolutionRaw) ?? .source,
            frameRate: OutputFrameRate(rawValue: outputFrameRateRaw) ?? .fps30,
            codec: OutputCodec(rawValue: outputCodecRaw) ?? .h264,
            bitrate: OutputBitrate(rawValue: outputBitrateRaw) ?? .automatic,
            orientation: OutputOrientation(rawValue: outputOrientationRaw) ?? .source
        )
    }
    var videoSources: [CaptureSourceItem] { sources.filter { $0.kind.isVideo } }
    var canvasSourcePixelSize: CGSize {
        let sourceID = compositionLayers.first(where: \.isVisible)?.sourceID
        guard let pixel = source(sourceID)?.latestPixelBuffer else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
    }
    var recordingTitle: String { storedRecordingTitle }
    var outputBaseDirectory: URL {
        if !storedOutputBaseDirectory.isEmpty {
            return URL(fileURLWithPath: storedOutputBaseDirectory, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/课录")
    }
    var outputCompatibilityWarning: String? {
        if !outputSettings.hasHardwareEncoder(sourceSize: canvasSourcePixelSize) {
            return "当前参数没有可用的硬件编码器，请降低分辨率/帧率或切换编码。"
        }
        let target = Double(outputSettings.frameRate.rawValue)
        let limitingSources = videoSources.filter {
            $0.isEnabled && $0.observedFrameRate > 0 && $0.observedFrameRate < target * 0.82
        }
        if !limitingSources.isEmpty {
            return "\(limitingSources.map(\.name).joined(separator: "、")) 实际帧率低于目标，成片不会自动补足到 \(Int(target)) fps。"
        }
        if outputSettings.resolution == .uhd2160,
           outputSettings.frameRate == .fps60,
           videoSources.filter(\.isEnabled).count >= 3 {
            return "4K 60 fps 加多路独立文件负载很高，正式录课前建议先试录 1 分钟。"
        }
        return nil
    }
    var canRecord: Bool {
        let visibleLayers = compositionLayers.filter(\.isVisible)
        guard !visibleLayers.isEmpty else { return false }
        let requiredVideoIDs = Set(visibleLayers.map(\.sourceID))
        guard requiredVideoIDs.allSatisfy({ source($0)?.isEnabled == true }) else { return false }
        return sources.filter {
            $0.isEnabled && (!$0.kind.isVideo || requiredVideoIDs.contains($0.id))
        }.allSatisfy { $0.errorText == nil }
    }

    init() {
        if templateSemanticsVersion < 2 {
            if templateRaw == CompositionTemplate.cameraScreenPip.rawValue {
                storeOverlay(.leftOverlay)
            }
            templateSemanticsVersion = 2
        }
        mobileDiscovery.onStreamersChanged = { [weak self] streamers in
            Task { @MainActor in self?.mobileStreamers = streamers }
        }
        localRTMPReceiver.onSnapshot = { [weak self] snapshot in
            self?.applyLocalRTMPSnapshot(snapshot)
        }
        localRTMPReceiver.start()
        Task { await requestPermissionsAndRefresh() }
    }

    func requestPermissionsAndRefresh() async {
        cameraPermissionGranted = await request(.video)
        micPermissionGranted = await request(.audio)
        screenPermissionGranted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        await refreshDevices()
        if sources.isEmpty {
            restoreSources()
            restoreCompositionLayers()
            restoreScenes()
        }
        ensureLocalRTMPSource()
        if !localRTMPIsPublishing, let sourceID = managedLocalRTMPSourceID {
            removeCompositionLayer(sourceID: sourceID)
        }
        if sources.allSatisfy({ isLocalRTMPSource($0.id) }) {
            if !displays.isEmpty { addSource(.screen) }
            if !cameras.isEmpty { addSource(.camera) }
        }
        statusText = "多源监看中"
        await scanRecoverableRecordings()
    }

    private func request(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    func refreshDevices() async {
        mobileDiscovery.restart()
        var video = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        video.append(contentsOf: AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera], mediaType: .video, position: .unspecified).devices)
        cameras = video
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            let pid = ProcessInfo.processInfo.processIdentifier
            let bundle = Bundle.main.bundleIdentifier
            excludedApplications = content.applications.filter { $0.processID == pid || (bundle != nil && $0.bundleIdentifier == bundle) }
            let excludedPIDs = Set(excludedApplications.map(\.processID))
            windows = content.windows.filter {
                $0.windowLayer == 0
                    && !excludedPIDs.contains($0.owningApplication?.processID ?? -1)
                    && !(($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } catch {
            statusText = "设备刷新失败：\(error.localizedDescription)"
            DiagnosticLogger.shared.error(
                error,
                category: "capture",
                operation: "refresh-devices"
            )
        }
        if !isRecording {
            for item in sources where item.isEnabled && item.errorText != nil {
                stopCapture(for: item)
                item.errorText = nil
                startCapture(for: item)
            }
        }
    }

    func addSource(_ kind: CaptureSourceKind) {
        let identifier: String?
        switch kind {
        case .screen: identifier = availableDisplays().first?.displayID.description
        case .window: identifier = availableWindows().first?.windowID.description
        case .camera: identifier = availableCameras().first?.uniqueID
        case .mobile: identifier = availableMobileStreamers().first?.sourceIdentifier
        case .rtmp: identifier = nil
        case .microphone: identifier = availableMicrophones().first?.uniqueID
        }
        guard let identifier else { statusText = "没有尚未添加的\(kind.label)"; return }
        addSource(kind, identifier: identifier)
    }

    func addSource(_ kind: CaptureSourceKind, identifier: String) {
        guard !isRecording else { return }
        guard !isDeviceInUse(kind: kind, identifier: identifier) else {
            statusText = "该\(kind.label)来源已经添加"
            return
        }
        guard !identifier.isEmpty else { statusText = "没有可用的\(kind.label)设备"; return }
        let count = sources.filter { $0.kind == kind }.count + 1
        let item = CaptureSourceItem(kind: kind, name: "\(kind.label) \(count)", deviceIdentifier: identifier)
        sources.append(item)
        if kind.isVideo {
            addCompositionLayer(sourceID: item.id)
        }
        startCapture(for: item)
        persistSources()
    }

    func removeSource(_ id: UUID) {
        guard !isLocalRTMPSource(id) else {
            statusText = "内置 RTMP 来源由接收服务自动管理"
            return
        }
        guard !isRecording, let item = source(id) else { return }
        stopCapture(for: item)
        sources.removeAll { $0.id == id }
        if let selectedCompositionLayerID,
           compositionLayer(selectedCompositionLayerID)?.sourceID == id {
            self.selectedCompositionLayerID = nil
        }
        compositionLayers.removeAll { $0.sourceID == id }
        if selectedCompositionLayerID == nil {
            selectedCompositionLayerID = compositionLayers.last?.id
        }
        if soloAudioSourceID == id {
            soloAudioSourceID = nil
            persistedSoloAudioSourceID = ""
        }
        if monitoredAudioSourceID == id {
            setSourceMonitoring(nil)
        }
        persistSources()
        compositionChanged()
    }

    func updateDevice(for id: UUID, identifier: String) {
        guard !isRecording, let item = source(id), item.deviceIdentifier != identifier else { return }
        guard !isDeviceInUse(kind: item.kind, identifier: identifier, excluding: id) else {
            statusText = "该\(item.kind.label)来源已经添加"
            return
        }
        stopCapture(for: item)
        item.deviceIdentifier = identifier
        item.frame = nil
        item.errorText = nil
        startCapture(for: item)
        persistSources()
    }

    func source(_ id: UUID?) -> CaptureSourceItem? { guard let id else { return nil }; return sources.first { $0.id == id } }
    func compositionLayer(_ id: UUID?) -> CompositionLayer? {
        guard let id else { return nil }
        return compositionLayers.first { $0.id == id }
    }

    func isLocalRTMPSource(_ id: UUID) -> Bool {
        managedLocalRTMPSourceID == id
    }

    func regenerateLocalRTMPStreamName() {
        guard !isRecording else { return }
        localRTMPReceiver.regenerateStreamName()
    }

    private func ensureLocalRTMPSource() {
        let sourceID: UUID
        if let saved = UUID(uuidString: persistedLocalRTMPSourceID) {
            sourceID = saved
        } else {
            sourceID = UUID()
            persistedLocalRTMPSourceID = sourceID.uuidString
        }
        managedLocalRTMPSourceID = sourceID

        if let item = source(sourceID) {
            item.name = "内置 RTMP"
            item.isEnabled = true
            applyLocalRTMPSnapshot(localRTMPReceiver.snapshot)
            return
        }

        let item = CaptureSourceItem(
            id: sourceID,
            kind: .rtmp,
            name: "内置 RTMP",
            deviceIdentifier: localRTMPReceiver.snapshot.playbackURL,
            isEnabled: true,
            recordsISO: false
        )
        item.errorText = localRTMPReceiver.snapshot.statusText
        sources.append(item)
        startCapture(for: item)
        persistSources()
    }

    private func applyLocalRTMPSnapshot(_ snapshot: LocalRTMPReceiver.Snapshot) {
        localRTMPPublishURL = snapshot.publishURL
        localRTMPStreamName = snapshot.streamName
        localRTMPStatusText = snapshot.statusText
        localRTMPIsReady = snapshot.isReady
        localRTMPIsPublishing = snapshot.phase == .publishing
        localRTMPHasLANAddress = snapshot.hasLANAddress

        guard let sourceID = managedLocalRTMPSourceID,
              let item = source(sourceID)
        else { return }

        let urlChanged = item.deviceIdentifier != snapshot.playbackURL
        if urlChanged {
            stopCapture(for: item)
            item.deviceIdentifier = snapshot.playbackURL
            item.frame = nil
            item.latestPixelBuffer = nil
            item.videoFormatText = ""
            startCapture(for: item)
        }
        if item.latestPixelBuffer == nil {
            item.errorText = snapshot.statusText
        }
        if urlChanged { persistSources() }
    }

    func availableDisplays(excluding sourceID: UUID? = nil) -> [SCDisplay] {
        displays.filter { !isDeviceInUse(kind: .screen, identifier: $0.displayID.description, excluding: sourceID) }
    }

    func availableCameras(excluding sourceID: UUID? = nil) -> [AVCaptureDevice] {
        cameras.filter { !isDeviceInUse(kind: .camera, identifier: $0.uniqueID, excluding: sourceID) }
    }

    func availableWindows(excluding sourceID: UUID? = nil) -> [SCWindow] {
        windows.filter { !isDeviceInUse(kind: .window, identifier: $0.windowID.description, excluding: sourceID) }
    }

    func availableMicrophones(excluding sourceID: UUID? = nil) -> [AVCaptureDevice] {
        microphones.filter { !isDeviceInUse(kind: .microphone, identifier: $0.uniqueID, excluding: sourceID) }
    }

    func availableMobileStreamers(excluding sourceID: UUID? = nil) -> [MobileStreamer] {
        mobileStreamers.filter {
            !isDeviceInUse(kind: .mobile, identifier: $0.sourceIdentifier, excluding: sourceID)
        }
    }

    private func isDeviceInUse(kind: CaptureSourceKind, identifier: String, excluding sourceID: UUID? = nil) -> Bool {
        sources.contains { $0.id != sourceID && $0.kind == kind && $0.deviceIdentifier == identifier }
    }

    private func startCapture(for item: CaptureSourceItem) {
        guard item.isEnabled else { return }
        switch item.kind {
        case .camera:
            guard let device = cameras.first(where: { $0.uniqueID == item.deviceIdentifier }) else {
                item.errorText = "摄像头未连接"
                return
            }
            let capture = CameraSourceCapture(id: item.id)
            capture.onBuffer = { [weak self] buffer in Task { @MainActor in self?.handleVideo(buffer, id: item.id) } }
            let targetSize = outputSettings.resolution.size(source: CGSize(width: 1920, height: 1080))
            do {
                try capture.start(
                    device: device,
                    targetSize: targetSize,
                    targetFrameRate: outputSettings.frameRate.rawValue
                )
                cameraCaptures[item.id] = capture
            }
            catch { reportSourceError(item, error: error, operation: "start-camera") }
        case .microphone:
            guard let device = microphones.first(where: { $0.uniqueID == item.deviceIdentifier }) else {
                item.errorText = "麦克风未连接"
                return
            }
            let capture = MicrophoneSourceCapture(id: item.id)
            capture.gainDB = item.gainDB
            capture.onBuffer = { [weak self] buffer in Task { @MainActor in self?.handleAudio(buffer, id: item.id, media: .microphoneAudio) } }
            capture.onLevel = { [weak self] average, peak, clip in Task { @MainActor in self?.handleLevel(id: item.id, average: average, peak: peak, clipping: clip) } }
            do { try capture.start(device: device); microphoneCaptures[item.id] = capture }
            catch { reportSourceError(item, error: error, operation: "start-microphone") }
        case .screen:
            guard let displayID = UInt32(item.deviceIdentifier), let display = displays.first(where: { $0.displayID == displayID }) else {
                item.errorText = "显示器未连接"
                return
            }
            let capture = ScreenSourceCapture(id: item.id)
            capture.onVideo = { [weak self] buffer in Task { @MainActor in self?.handleVideo(buffer, id: item.id) } }
            capture.onAudio = { [weak self] buffer in Task { @MainActor in self?.handleAudio(buffer, id: item.id, media: .systemAudio) } }
            capture.onError = { [weak self] error in Task { @MainActor in self?.handleCaptureError(id: item.id, error: error) } }
            screenCaptures[item.id] = capture
            Task {
                do {
                    try await capture.start(
                        display: display,
                        excludedApplications: excludedApplications,
                        recording: false
                    )
                } catch {
                    reportSourceError(item, error: error, operation: "start-screen")
                }
            }
        case .window:
            guard let windowID = UInt32(item.deviceIdentifier),
                  let window = windows.first(where: { $0.windowID == windowID })
            else {
                item.errorText = "窗口已关闭，请重新选择"
                return
            }
            let capture = ScreenSourceCapture(id: item.id)
            capture.onVideo = { [weak self] buffer in Task { @MainActor in self?.handleVideo(buffer, id: item.id) } }
            capture.onAudio = { [weak self] buffer in Task { @MainActor in self?.handleAudio(buffer, id: item.id, media: .systemAudio) } }
            capture.onError = { [weak self] error in Task { @MainActor in self?.handleCaptureError(id: item.id, error: error) } }
            screenCaptures[item.id] = capture
            Task {
                do { try await capture.start(window: window, recording: false) }
                catch { reportSourceError(item, error: error, operation: "start-window") }
            }
        case .mobile:
            guard let streamer = MobileStreamer(sourceIdentifier: item.deviceIdentifier) else {
                item.errorText = "移动端地址无效"
                return
            }
            let expectedKind: MobileSourceKind = streamer.sourceKind == .unknown
                ? .screen
                : streamer.sourceKind
            let capture = MobileInputClient()
            capture.onVideo = { [weak self] buffer in
                Task { @MainActor in self?.handleVideo(buffer, id: item.id) }
            }
            capture.onAudio = { [weak self] buffer in
                let media: RoutedBufferSource.Media = expectedKind == .camera
                    ? .microphoneAudio
                    : .systemAudio
                Task { @MainActor in self?.handleAudio(buffer, id: item.id, media: media) }
            }
            capture.onStatus = { [weak self] status in
                Task { @MainActor in self?.handleNetworkStatus(id: item.id, status: status) }
            }
            mobileCaptures[item.id] = capture
            item.errorText = "正在连接 \(streamer.host)…"
            capture.start(streamer: streamer, expectedKind: expectedKind)
        case .rtmp:
            let url = item.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                item.errorText = "请输入 RTMP 拉流地址"
                return
            }
            let capture = RTMPInputClient()
            capture.onVideo = { [weak self] buffer in
                Task { @MainActor in self?.handleVideo(buffer, id: item.id) }
            }
            capture.onStatus = { [weak self] status in
                Task { @MainActor in self?.handleNetworkStatus(id: item.id, status: status) }
            }
            rtmpCaptures[item.id] = capture
            item.errorText = "正在连接 RTMP…"
            capture.start(urlString: url)
        }
    }

    private func stopCapture(for item: CaptureSourceItem) {
        cameraCaptures.removeValue(forKey: item.id)?.stop()
        microphoneCaptures.removeValue(forKey: item.id)?.stop()
        if let capture = screenCaptures.removeValue(forKey: item.id) { Task { await capture.stop() } }
        mobileCaptures.removeValue(forKey: item.id)?.stop()
        rtmpCaptures.removeValue(forKey: item.id)?.stop()
    }

    private func handleVideo(_ buffer: CMSampleBuffer, id: UUID) {
        guard let item = source(id), item.isEnabled, let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        item.errorText = nil
        item.latestPixelBuffer = pixel
        updateVideoFormat(item: item, buffer: buffer, pixel: pixel)
        if let recordingSession { recordingSession.handleBuffer(buffer, source: RoutedBufferSource(id: id, media: .video)) }
        scheduleSourcePreview(item, pixel: pixel)
        scheduleProgramPreview()
    }

    private func handleAudio(_ buffer: CMSampleBuffer, id: UUID, media: RoutedBufferSource.Media) {
        guard let item = source(id), item.isEnabled else { return }
        if monitoredAudioSourceID == id {
            audioMonitor.enqueue(buffer)
        }
        guard !item.isMuted,
              soloAudioSourceID == nil || soloAudioSourceID == id
        else { return }
        recordingSession?.handleBuffer(buffer, source: RoutedBufferSource(id: id, media: media))
    }

    private func handleLevel(id: UUID, average: Double, peak: Double, clipping: Bool) {
        guard let item = source(id) else { return }
        item.averageLevel = average
        item.peakLevel = max(peak, item.peakLevel * 0.9)
        if clipping { clipHold[id] = Date().addingTimeInterval(1) }
        item.isClipping = Date() < (clipHold[id] ?? .distantPast)
    }

    private func reportSourceError(
        _ item: CaptureSourceItem,
        error: Error,
        operation: String
    ) {
        item.errorText = error.localizedDescription
        DiagnosticLogger.shared.error(
            error,
            category: "capture",
            operation: operation,
            metadata: sourceLogMetadata(item, operation: operation)
        )
    }

    private func sourceLogMetadata(
        _ item: CaptureSourceItem,
        operation: String
    ) -> [String: String] {
        [
            "operation": operation,
            "source_id": String(item.id.uuidString.prefix(8)),
            "source_kind": item.kind.rawValue
        ]
    }

    private func handleCaptureError(id: UUID, error: Error) {
        guard let item = source(id) else { return }
        reportSourceError(item, error: error, operation: "capture-interrupted")
        statusText = "\(item.name) 采集中断：\(error.localizedDescription)"
    }

    private func handleNetworkStatus(id: UUID, status: String) {
        guard let item = source(id), item.isEnabled else { return }
        if isLocalRTMPSource(id), item.latestPixelBuffer == nil {
            item.errorText = localRTMPIsReady ? "等待 RTMP 推流" : localRTMPStatusText
            return
        }
        if status.contains("已连接") {
            item.errorText = nil
        } else if item.latestPixelBuffer == nil || status.contains("断开") || status.contains("失败") || status.contains("无效") {
            let previousStatus = item.errorText
            item.errorText = status
            if previousStatus != status,
               status.contains("断开") || status.contains("失败") || status.contains("无效") {
                DiagnosticLogger.shared.log(
                    .warning,
                    category: "network-input",
                    status,
                    metadata: sourceLogMetadata(item, operation: "status")
                )
            }
        }
        statusText = "\(item.name)：\(status)"
    }

    private func scheduleSourcePreview(_ item: CaptureSourceItem, pixel: CVPixelBuffer) {
        let now = Date(); guard now.timeIntervalSince(lastSourcePreview[item.id] ?? .distantPast) > 0.16 else { return }
        guard !sourcePreviewPending.contains(item.id) else { return }
        lastSourcePreview[item.id] = now
        sourcePreviewPending.insert(item.id)
        let itemID = item.id
        let box = SendablePixelBuffer(value: pixel), context = previewContext
        sourcePreviewQueue.async { [weak self, weak item] in
            let image = Self.makePreview(box.value, context: context)
            Task { @MainActor in
                item?.frame = image
                self?.sourcePreviewPending.remove(itemID)
            }
        }
    }

    private func scheduleProgramPreview(force: Bool = false) {
        let now = Date(); guard force || now.timeIntervalSince(lastProgramPreview) > 0.1 else { return }
        guard !programPreviewPending else { return }
        let layerBoxes: [(buffer: SendablePixelBuffer, layer: CompositionLayer)] = compositionLayers.compactMap { layer in
            guard layer.isVisible,
                  let pixel = source(layer.sourceID)?.latestPixelBuffer
            else { return nil }
            return (buffer: SendablePixelBuffer(value: pixel), layer: layer)
        }
        guard let canvasBox = layerBoxes.first?.buffer else {
            composedFrame = nil
            outputResolutionText = "等待输出图层"
            return
        }
        lastProgramPreview = now; programPreviewPending = true
        let compositor = previewCompositor
        let resolution = outputSettings.resolution
        let orientation = outputSettings.orientation
        programPreviewQueue.async { [weak self] in
            let sourceSize = CGSize(width: CVPixelBufferGetWidth(canvasBox.value), height: CVPixelBufferGetHeight(canvasBox.value))
            let selectedSize = orientation.apply(to: resolution.size(source: sourceSize))
            let image = compositor.makePreview(
                frames: layerBoxes.map { (frame: $0.buffer.value, layer: $0.layer) },
                outputSize: selectedSize
            )
            let resolution = "\(Int(selectedSize.width)) × \(Int(selectedSize.height))"
            Task { @MainActor in self?.composedFrame = image; self?.outputResolutionText = resolution; self?.programPreviewPending = false }
        }
    }

    private nonisolated static func makePreview(_ buffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 480 / max(image.extent.width, image.extent.height))
        let output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(output, from: output.extent)
    }

    func selectTemplate(_ template: CompositionTemplate) {
        templateRaw = template.rawValue
        let indices = compositionLayers.indices.filter { compositionLayers[$0].isVisible }
        guard let first = indices.first else { return }
        switch template {
        case .screenOnly:
            compositionLayers[first].rect = .fullCanvas
            compositionLayers[first].displayMode = .fit
        case .cameraOnly:
            compositionLayers[first].rect = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
            compositionLayers[first].displayMode = .fit
        case .screenCameraPip, .cameraScreenPip:
            compositionLayers[first].rect = .fullCanvas
            compositionLayers[first].displayMode = .fit
            if indices.count > 1 {
                compositionLayers[indices[1]].rect = template == .screenCameraPip ? .defaultOverlay : .leftOverlay
                compositionLayers[indices[1]].displayMode = .fill
            }
        case .presenterSplit:
            compositionLayers[first].rect = NormalizedRect(x: 0, y: 0, width: 0.72, height: 1)
            compositionLayers[first].displayMode = .fit
            if indices.count > 1 {
                compositionLayers[indices[1]].rect = NormalizedRect(x: 0.72, y: 0, width: 0.28, height: 1)
                compositionLayers[indices[1]].displayMode = .fill
            }
        case .equalSplit:
            compositionLayers[first].rect = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
            compositionLayers[first].displayMode = .fill
            if indices.count > 1 {
                compositionLayers[indices[1]].rect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
                compositionLayers[indices[1]].displayMode = .fill
            }
        }
        selectedLayerEditorMode = .frame
        compositionChanged()
    }
    func setOutputResolution(_ value: OutputResolution) { guard !isRecording else { return }; outputResolutionRaw = value.rawValue; markSceneDirty(); objectWillChange.send(); restartCameraCaptures(); scheduleProgramPreview(force: true) }
    func setOutputOrientation(_ value: OutputOrientation) { guard !isRecording else { return }; outputOrientationRaw = value.rawValue; markSceneDirty(); objectWillChange.send(); scheduleProgramPreview(force: true) }
    func setOutputFrameRate(_ value: OutputFrameRate) { guard !isRecording else { return }; outputFrameRateRaw = value.rawValue; markSceneDirty(); objectWillChange.send(); restartCameraCaptures() }
    func setOutputCodec(_ value: OutputCodec) { guard !isRecording else { return }; outputCodecRaw = value.rawValue; markSceneDirty(); objectWillChange.send() }
    func setOutputBitrate(_ value: OutputBitrate) { guard !isRecording else { return }; outputBitrateRaw = value.rawValue; markSceneDirty(); objectWillChange.send() }

    func applyOutputPreset(_ preset: OutputPreset) {
        guard !isRecording else { return }
        switch preset {
        case .compatible:
            outputResolutionRaw = OutputResolution.fullHD1080.rawValue
            outputOrientationRaw = OutputOrientation.landscape.rawValue
            outputFrameRateRaw = OutputFrameRate.fps30.rawValue
            outputCodecRaw = OutputCodec.h264.rawValue
            outputBitrateRaw = OutputBitrate.mbps12.rawValue
        case .highQuality:
            outputResolutionRaw = OutputResolution.qhd1440.rawValue
            outputOrientationRaw = OutputOrientation.landscape.rawValue
            outputFrameRateRaw = OutputFrameRate.fps30.rawValue
            outputCodecRaw = OutputCodec.hevc.rawValue
            outputBitrateRaw = OutputBitrate.mbps20.rawValue
        case .ultraHD:
            outputResolutionRaw = OutputResolution.uhd2160.rawValue
            outputOrientationRaw = OutputOrientation.landscape.rawValue
            outputFrameRateRaw = OutputFrameRate.fps60.rawValue
            outputCodecRaw = OutputCodec.hevc.rawValue
            outputBitrateRaw = OutputBitrate.automatic.rawValue
        case .portraitCourse:
            outputResolutionRaw = OutputResolution.fullHD1080.rawValue
            outputOrientationRaw = OutputOrientation.portrait.rawValue
            outputFrameRateRaw = OutputFrameRate.fps30.rawValue
            outputCodecRaw = OutputCodec.h264.rawValue
            outputBitrateRaw = OutputBitrate.mbps12.rawValue
        }
        markSceneDirty()
        objectWillChange.send()
        restartCameraCaptures()
        scheduleProgramPreview(force: true)
    }

    var availableCompositionLayerSources: [CaptureSourceItem] {
        let used = Set(compositionLayers.map(\.sourceID))
        return videoSources.filter {
            $0.isEnabled
                && !used.contains($0.id)
        }
    }

    func compositionLayer(forSource sourceID: UUID) -> CompositionLayer? {
        compositionLayers.first { $0.sourceID == sourceID }
    }

    func addCompositionLayer(sourceID: UUID) {
        guard source(sourceID)?.kind.isVideo == true,
              !compositionLayers.contains(where: { $0.sourceID == sourceID })
        else { return }
        let isFirst = compositionLayers.isEmpty
        let offset = Double(compositionLayers.count % 4) * 0.03
        let layer = CompositionLayer(
            sourceID: sourceID,
            rect: isFirst
                ? .fullCanvas
                : NormalizedRect(x: 0.66 - offset, y: 0.08 + offset, width: 0.3, height: 0.3),
            displayMode: isFirst ? .fit : .fill
        )
        compositionLayers.append(layer)
        selectedCompositionLayerID = layer.id
        compositionChanged()
    }

    func removeCompositionLayer(_ id: UUID) {
        compositionLayers.removeAll { $0.id == id }
        if selectedCompositionLayerID == id {
            selectedCompositionLayerID = compositionLayers.last?.id
        }
        compositionChanged()
    }

    func removeCompositionLayer(sourceID: UUID) {
        guard let layer = compositionLayer(forSource: sourceID) else { return }
        removeCompositionLayer(layer.id)
    }

    func setSelectedLayerEditorMode(_ mode: LayerEditorMode) {
        guard let layer = compositionLayer(selectedCompositionLayerID) else {
            selectedLayerEditorMode = .frame
            return
        }
        selectedLayerEditorMode = mode == .crop && layer.displayMode != .fill ? .frame : mode
    }

    func updateCompositionLayer(
        _ id: UUID,
        minimumSize: Double = 0.08,
        _ update: (inout CompositionLayer) -> Void
    ) {
        guard let index = compositionLayers.firstIndex(where: { $0.id == id }) else { return }
        update(&compositionLayers[index])
        compositionLayers[index].rect = compositionLayers[index].rect.clamped(minimumSize: minimumSize)
        compositionLayers[index].anchorX = min(1, max(0, compositionLayers[index].anchorX))
        compositionLayers[index].anchorY = min(1, max(0, compositionLayers[index].anchorY))
        if compositionLayers[index].displayMode != .fill,
           selectedCompositionLayerID == id {
            selectedLayerEditorMode = .frame
        }
        compositionChanged()
    }

    func sourceAspectRatio(forCompositionLayer id: UUID) -> Double? {
        guard let layer = compositionLayer(id),
              let pixelBuffer = source(layer.sourceID)?.latestPixelBuffer
        else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    func matchCompositionLayerToSourceAspect(_ id: UUID) {
        guard let layer = compositionLayer(id),
              let normalizedAspect = normalizedSourceAspect(forCompositionLayer: id)
        else { return }
        let currentAspect = layer.rect.width / layer.rect.height
        let size: (width: Double, height: Double)
        if currentAspect > normalizedAspect {
            size = (layer.rect.height * normalizedAspect, layer.rect.height)
        } else {
            size = (layer.rect.width, layer.rect.width / normalizedAspect)
        }
        let centerX = layer.rect.x + layer.rect.width / 2
        let centerY = layer.rect.y + layer.rect.height / 2
        updateCompositionLayer(id) {
            $0.rect = NormalizedRect(
                x: centerX - size.width / 2,
                y: centerY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    func applyCompositionLayerSizePreset(_ preset: LayerSizePreset, to id: UUID) {
        guard let layer = compositionLayer(id) else { return }
        let retainedPosition = LayerPositionPreset.matching(layer.rect)
        let normalizedAspect = normalizedSourceAspect(forCompositionLayer: id)
        let fittedSize: (width: Double, height: Double)
        if let normalizedAspect, normalizedAspect > 0 {
            fittedSize = normalizedAspect >= 1
                ? (1, 1 / normalizedAspect)
                : (normalizedAspect, 1)
        } else {
            fittedSize = (1, 1)
        }
        let width = fittedSize.width * preset.rawValue
        let height = fittedSize.height * preset.rawValue
        let currentCenter = (
            x: layer.rect.x + layer.rect.width / 2,
            y: layer.rect.y + layer.rect.height / 2
        )
        let origin = retainedPosition?.origin(width: width, height: height)
            ?? (x: currentCenter.x - width / 2, y: currentCenter.y - height / 2)

        updateCompositionLayer(id, minimumSize: 0.01) {
            $0.rect = NormalizedRect(x: origin.x, y: origin.y, width: width, height: height)
        }
        selectedLayerEditorMode = .frame
    }

    func applyCompositionLayerPositionPreset(_ preset: LayerPositionPreset, to id: UUID) {
        guard let layer = compositionLayer(id) else { return }
        let origin = preset.origin(width: layer.rect.width, height: layer.rect.height)
        updateCompositionLayer(id, minimumSize: 0.01) {
            $0.rect.x = origin.x
            $0.rect.y = origin.y
        }
        selectedLayerEditorMode = .frame
    }

    func resetCompositionLayerFrame(_ id: UUID) {
        guard let normalizedAspect = normalizedSourceAspect(forCompositionLayer: id) else {
            updateCompositionLayer(id) {
                $0.rect = .fullCanvas
                $0.anchorX = 0.5
                $0.anchorY = 0.5
            }
            return
        }
        let size: (width: Double, height: Double) = normalizedAspect >= 1
            ? (1, 1 / normalizedAspect)
            : (normalizedAspect, 1)
        updateCompositionLayer(id) {
            $0.rect = NormalizedRect(
                x: (1 - size.width) / 2,
                y: (1 - size.height) / 2,
                width: size.width,
                height: size.height
            )
            $0.anchorX = 0.5
            $0.anchorY = 0.5
        }
    }

    private func normalizedSourceAspect(forCompositionLayer id: UUID) -> Double? {
        guard let sourceAspect = sourceAspectRatio(forCompositionLayer: id) else { return nil }
        let outputSize = outputSettings.size(source: canvasSourcePixelSize)
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }
        return sourceAspect / (outputSize.width / outputSize.height)
    }

    func moveCompositionLayer(_ id: UUID, offset: Int) {
        guard let index = compositionLayers.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(compositionLayers.count - 1, max(0, index + offset))
        guard destination != index else { return }
        let layer = compositionLayers.remove(at: index)
        compositionLayers.insert(layer, at: destination)
        compositionChanged()
    }

    func moveCompositionLayer(_ id: UUID, over targetID: UUID) {
        guard id != targetID,
              let sourceIndex = compositionLayers.firstIndex(where: { $0.id == id }),
              let targetIndex = compositionLayers.firstIndex(where: { $0.id == targetID })
        else { return }

        let layer = compositionLayers.remove(at: sourceIndex)
        guard let updatedTargetIndex = compositionLayers.firstIndex(where: { $0.id == targetID }) else {
            compositionLayers.insert(layer, at: sourceIndex)
            return
        }
        let destination = sourceIndex < targetIndex ? updatedTargetIndex + 1 : updatedTargetIndex
        compositionLayers.insert(layer, at: destination)
        compositionChanged()
    }

    func saveCurrentScene() {
        guard !compositionLayers.isEmpty else { return }
        let existing = activeSceneID.flatMap { id in savedScenes.first(where: { $0.id == id }) }
        let name = existing?.name ?? nextSceneName()
        let snapshot = currentSceneSnapshot(name: name)
        guard let snapshot else { return }
        let targetID = existing?.id ?? snapshot.id
        let updated = snapshotWithID(snapshot, id: targetID)
        if let index = savedScenes.firstIndex(where: { $0.id == targetID }) {
            savedScenes[index] = updated
        } else {
            savedScenes.append(updated)
        }
        finishSavingScene(updated)
    }

    @discardableResult
    func saveCurrentSceneAs(name: String) -> Bool {
        guard !compositionLayers.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "请输入场景名称"
            return false
        }
        guard !savedScenes.contains(where: { $0.name == trimmed }) else {
            statusText = "场景名称已存在"
            return false
        }
        guard let snapshot = currentSceneSnapshot(name: trimmed) else { return false }
        sceneAutosaveTask?.cancel()
        sceneAutosaveTask = nil
        savedScenes.append(snapshot)
        finishSavingScene(snapshot)
        return true
    }

    func applyScene(_ id: UUID) {
        guard id != activeSceneID else { return }
        flushPendingSceneAutosave()
        guard let scene = savedScenes.first(where: { $0.id == id }) else { return }
        guard applySceneSnapshot(scene) else {
            statusText = "场景中的视频来源未连接"
            return
        }
        let missingCount = scene.layers.filter { source($0.sourceID)?.isEnabled != true }.count
        activeSceneID = scene.id
        persistedActiveSceneID = scene.id.uuidString
        setSceneDirty(false)
        statusText = missingCount == 0
            ? "已切换场景：\(scene.name)"
            : "已切换场景：\(scene.name)（\(missingCount) 个来源未连接）"
    }

    @discardableResult
    func renameActiveScene(to name: String) -> Bool {
        guard let activeSceneID,
              let index = savedScenes.firstIndex(where: { $0.id == activeSceneID })
        else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "请输入场景名称"
            return false
        }
        guard !savedScenes.contains(where: { $0.id != activeSceneID && $0.name == trimmed }) else {
            statusText = "场景名称已存在"
            return false
        }
        savedScenes[index].name = trimmed
        persistScenes()
        statusText = "已重命名场景：\(trimmed)"
        return true
    }

    @discardableResult
    func duplicateActiveScene() -> Bool {
        flushPendingSceneAutosave()
        guard let activeSceneID,
              let current = savedScenes.first(where: { $0.id == activeSceneID }),
              let snapshot = currentSceneSnapshot(name: uniqueSceneName(base: "\(current.name) 副本"))
        else { return false }
        savedScenes.append(snapshot)
        finishSavingScene(snapshot)
        statusText = "已复制场景：\(snapshot.name)"
        return true
    }

    func currentSceneSnapshot(name: String = "当前场景") -> CompositionScene? {
        guard !compositionLayers.isEmpty else { return nil }
        return CompositionScene(
            name: name,
            layers: compositionLayers,
            audioStates: sources.filter {
                $0.kind == .microphone || $0.kind == .screen || $0.kind == .window
            }.map {
                SceneAudioState(sourceID: $0.id, isMuted: $0.isMuted, recordsISO: $0.recordsISO, gainDB: $0.gainDB)
            },
            soloAudioSourceID: soloAudioSourceID,
            transition: selectedTransition,
            outputSettings: outputSettings,
            recordingTitle: recordingTitle
        )
    }

    @discardableResult
    func applySceneSnapshot(_ scene: CompositionScene) -> Bool {
        let sourceIDs = Set(videoSources.filter(\.isEnabled).map(\.id))
        guard scene.layers.contains(where: { $0.isVisible && sourceIDs.contains($0.sourceID) }) else {
            return false
        }
        compositionLayers = scene.layers
        selectedCompositionLayerID = compositionLayers.last?.id
        selectedLayerEditorMode = .frame
        if let transition = scene.transition {
            sceneTransitionRaw = transition.rawValue
        }
        if !isRecording {
            if let settings = scene.outputSettings {
                outputResolutionRaw = settings.resolution.rawValue
                outputOrientationRaw = settings.orientation.rawValue
                outputFrameRateRaw = settings.frameRate.rawValue
                outputCodecRaw = settings.codec.rawValue
                outputBitrateRaw = settings.bitrate.rawValue
            }
            if let title = scene.recordingTitle {
                storedRecordingTitle = title
            }
            for state in scene.audioStates {
                guard let item = source(state.sourceID) else { continue }
                item.isMuted = state.isMuted
                item.recordsISO = state.recordsISO
                item.gainDB = state.gainDB
                microphoneCaptures[state.sourceID]?.gainDB = state.gainDB
            }
            soloAudioSourceID = scene.soloAudioSourceID.flatMap { source($0) != nil ? $0 : nil }
            restartCameraCaptures()
        }
        persistSources()
        persistCompositionLayers()
        objectWillChange.send()
        scheduleProgramPreview(force: true)
        syncLiveComposition()
        return true
    }

    func deleteScene(_ id: UUID) {
        let deletesActiveScene = activeSceneID == id
        if deletesActiveScene {
            sceneAutosaveTask?.cancel()
            sceneAutosaveTask = nil
        }
        savedScenes.removeAll { $0.id == id }
        if deletesActiveScene {
            activeSceneID = nil
            persistedActiveSceneID = ""
            setSceneDirty(false)
        }
        persistScenes()
        guard deletesActiveScene, let fallback = savedScenes.first else { return }
        guard applySceneSnapshot(fallback) else { return }
        activeSceneID = fallback.id
        persistedActiveSceneID = fallback.id.uuidString
        statusText = "已切换场景：\(fallback.name)"
    }

    func setRecordingTitle(_ value: String) {
        guard !isRecording else { return }
        storedRecordingTitle = value
        markSceneDirty()
    }

    func setOutputBaseDirectory(_ url: URL) {
        guard !isRecording else { return }
        storedOutputBaseDirectory = url.standardizedFileURL.path
        statusText = "输出目录已设置"
        Task { await scanRecoverableRecordings() }
    }

    func scanRecoverableRecordings() async {
        let base = outputBaseDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            recoverablePartialFiles = []
            return
        }
        let candidates = enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.contains(".partial.")
                && ["mov", "m4a"].contains($0.pathExtension.lowercased())
        }
        var valid: [URL] = []
        for url in candidates {
            let asset = AVURLAsset(url: url)
            if let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
                valid.append(url)
            }
        }
        recoverablePartialFiles = valid
        if !valid.isEmpty, !isRecording {
            statusText = "发现 \(valid.count) 个可恢复的未完成文件"
        }
    }

    func recoverPartialRecordings() async {
        var recovered = 0
        var failed = 0
        for url in recoverablePartialFiles {
            let baseName = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".partial", with: "")
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-已恢复")
                .appendingPathExtension(url.pathExtension)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: url, to: target)
                recovered += 1
            } catch {
                failed += 1
                DiagnosticLogger.shared.error(
                    error,
                    category: "recovery",
                    operation: "recover-partial-recording",
                    metadata: ["file": url.lastPathComponent]
                )
            }
        }
        await scanRecoverableRecordings()
        statusText = failed == 0
            ? "已恢复 \(recovered) 个文件"
            : "已恢复 \(recovered) 个文件，\(failed) 个失败"
    }

    func renameSource(_ id: UUID, name: String) {
        guard !isRecording, let item = source(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        item.name = trimmed
        persistSources()
    }

    func setSourceEnabled(_ id: UUID, enabled: Bool) {
        guard !isLocalRTMPSource(id) else { return }
        guard !isRecording, let item = source(id), item.isEnabled != enabled else { return }
        item.isEnabled = enabled
        item.errorText = nil
        if enabled {
            startCapture(for: item)
        } else {
            stopCapture(for: item)
            item.frame = nil
            item.latestPixelBuffer = nil
            if item.kind.isVideo,
               let index = compositionLayers.firstIndex(where: { $0.sourceID == id }) {
                compositionLayers[index].isVisible = false
            }
            if soloAudioSourceID == id {
                soloAudioSourceID = nil
                persistedSoloAudioSourceID = ""
            }
            if monitoredAudioSourceID == id {
                setSourceMonitoring(nil)
            }
        }
        persistSources()
        if item.kind.isVideo { compositionChanged() }
        else { scheduleProgramPreview(force: true) }
    }

    func setSourceRecordsISO(_ id: UUID, enabled: Bool) {
        guard !isRecording, let item = source(id) else { return }
        item.recordsISO = enabled
        persistSources()
        markSceneDirty()
    }

    func setSourceMuted(_ id: UUID, muted: Bool) {
        guard !isRecording, let item = source(id) else { return }
        item.isMuted = muted
        persistSources()
        markSceneDirty()
    }

    func toggleSourceSolo(_ id: UUID) {
        setSourceSolo(soloAudioSourceID == id ? nil : id)
    }

    func setSourceSolo(_ id: UUID?) {
        guard !isRecording else { return }
        if let id {
            guard let item = source(id), item.isEnabled,
                  item.kind == .microphone || item.kind == .screen || item.kind == .window
            else { return }
        }
        soloAudioSourceID = id
        persistedSoloAudioSourceID = soloAudioSourceID?.uuidString ?? ""
        markSceneDirty()
    }

    func toggleSourceMonitoring(_ id: UUID) {
        setSourceMonitoring(monitoredAudioSourceID == id ? nil : id)
    }

    func setSourceMonitoring(_ id: UUID?) {
        if let id {
            guard let item = source(id), item.isEnabled,
                  item.kind == .microphone || item.kind == .screen || item.kind == .window
            else { return }
        }
        audioMonitor.stop()
        monitoredAudioSourceID = id
    }

    func setSceneTransition(_ value: SceneTransition) {
        sceneTransitionRaw = value.rawValue
        markSceneDirty()
        objectWillChange.send()
    }

    func setSourceGain(_ id: UUID, gainDB: Double) {
        guard let item = source(id), item.kind == .microphone else { return }
        item.gainDB = min(12, max(-12, gainDB))
        microphoneCaptures[id]?.gainDB = item.gainDB
        persistSources()
        markSceneDirty()
    }

    private func storeOverlay(_ rect: NormalizedRect) {
        overlayX = rect.x; overlayY = rect.y
        overlayWidth = rect.width; overlayHeight = rect.height
    }

    private func storePrimaryRect(_ rect: NormalizedRect) {
        primaryX = rect.x
        primaryY = rect.y
        primaryWidth = rect.width
        primaryHeight = rect.height
    }

    func toggleRecording() async { if isRecording { await stopRecording() } else { await startRecording() } }
    private func startRecording() async {
        guard canRecord,
              let driverLayer = compositionLayers.first(where: \.isVisible)
        else {
            statusText = "请至少添加并显示一个可用的视频图层"
            return
        }
        guard let driverBuffer = source(driverLayer.sourceID)?.latestPixelBuffer else {
            statusText = "正在等待首个输出图层画面"
            return
        }
        let baseDir = outputBaseDirectory
        do {
            try preflightRecording(
                baseDir: baseDir,
                sourceSize: CGSize(
                    width: CVPixelBufferGetWidth(driverBuffer),
                    height: CVPixelBufferGetHeight(driverBuffer)
                )
            )
        } catch {
            statusText = error.localizedDescription
            DiagnosticLogger.shared.error(
                error,
                category: "recording",
                operation: "preflight"
            )
            return
        }
        let soloID = soloAudioSourceID
        let screenLikeSources = sources.filter {
            $0.isEnabled && ($0.kind == .screen || $0.kind == .window)
        }
        let systemAudioCandidates = sources.filter {
            guard $0.isEnabled else { return false }
            if $0.kind == .screen || $0.kind == .window { return true }
            guard $0.kind == .mobile,
                  let streamer = MobileStreamer(sourceIdentifier: $0.deviceIdentifier)
            else { return false }
            return streamer.sourceKind != .camera
        }
        let systemAudioSourceID = systemAudioCandidates.first(where: {
            !$0.isMuted && (soloID == nil || $0.id == soloID)
        })?.id
        let outputSourceIDs = Set(compositionLayers.filter(\.isVisible).map(\.sourceID))
        let definitions = sources.filter {
            guard $0.isEnabled else { return false }
            if $0.kind == .microphone || $0.id == systemAudioSourceID { return true }
            if outputSourceIDs.contains($0.id) { return true }
            return $0.kind.isVideo && $0.recordsISO && $0.latestPixelBuffer != nil
        }.map {
            RecordingSourceDefinition(
                id: $0.id,
                kind: $0.kind,
                name: $0.name,
                deviceIdentifier: $0.deviceIdentifier,
                recordsISO: $0.recordsISO,
                isMuted: $0.isMuted || (soloID != nil && $0.id != soloID),
                capturesSystemAudio: $0.id == systemAudioSourceID,
                mobileAudioRole: mobileAudioRole(for: $0)
            )
        }
        let session: RecordingSession
        do {
            session = try RecordingSession(
                baseDir: baseDir,
                sources: definitions,
                layers: compositionLayers,
                outputSettings: outputSettings,
                recordingTitle: recordingTitle
            )
        } catch {
            statusText = "无法创建输出目录：\(error.localizedDescription)"
            DiagnosticLogger.shared.error(
                error,
                category: "recording",
                operation: "create-session"
            )
            return
        }
        recordingSession = session
        for item in screenLikeSources {
            guard let capture = screenCaptures[item.id] else {
                await rollbackRecordingStart(session, reason: "来源 \(item.name) 已断开")
                return
            }
            do {
                switch item.kind {
                case .screen:
                    guard let displayID = UInt32(item.deviceIdentifier),
                          let display = displays.first(where: { $0.displayID == displayID })
                    else { throw CaptureSourceError.disconnected(item.name) }
                    try await capture.start(
                        display: display,
                        excludedApplications: excludedApplications,
                        recording: true,
                        capturesAudio: item.id == systemAudioSourceID,
                        frameRate: outputSettings.frameRate.rawValue
                    )
                case .window:
                    guard let windowID = UInt32(item.deviceIdentifier),
                          let window = windows.first(where: { $0.windowID == windowID })
                    else { throw CaptureSourceError.disconnected(item.name) }
                    try await capture.start(
                        window: window,
                        recording: true,
                        capturesAudio: item.id == systemAudioSourceID,
                        frameRate: outputSettings.frameRate.rawValue
                    )
                case .camera, .mobile, .rtmp, .microphone:
                    break
                }
            }
            catch {
                reportSourceError(item, error: error, operation: "start-recording-capture")
                await rollbackRecordingStart(session, reason: "\(item.name) 启动失败：\(error.localizedDescription)")
                return
            }
        }
        isRecording = true
        lastRecordingFolder = nil
        lastRecordingResult = nil
        markerCount = 0
        statusText = "录制中"
        recordingHealthText = "目标 \(outputSettings.frameRate.rawValue) fps · 等待统计"
        recordingHealthIsWarning = false
        lastHealthSampleDate = Date()
        lastHealthCPUTime = Self.processCPUTime()
        lastHealthWrittenBytes = 0
        startTimer()
    }

    private func mobileAudioRole(for item: CaptureSourceItem) -> RecordingMobileAudioRole {
        guard item.kind == .mobile,
              let streamer = MobileStreamer(sourceIdentifier: item.deviceIdentifier)
        else { return .none }
        return streamer.sourceKind == .camera ? .microphone : .system
    }

    private func stopRecording() async {
        isRecording = false; elapsedTask?.cancel(); elapsedTask = nil; statusText = "正在写入文件…"
        for capture in screenCaptures.values { await capture.stop() }
        let session = recordingSession; recordingSession = nil
        if let session {
            let result = await withCheckedContinuation { continuation in
                session.finish { continuation.resume(returning: $0) }
            }
            lastRecordingFolder = session.folderURL
            lastRecordingResult = result
            statusText = result.statusText
            DiagnosticLogger.shared.log(
                result.succeeded ? .info : .error,
                category: "recording",
                result.statusText,
                metadata: [
                    "folder": session.folderURL.lastPathComponent,
                    "dropped_buffers": String(result.droppedBuffers),
                    "files": String(result.files.count)
                ]
            )
        }
        elapsedText = "00:00"
        recordingHealthText = ""
        recordingHealthIsWarning = false
        for item in sources where item.kind == .screen || item.kind == .window { startCapture(for: item) }
    }

    func addMarker() { recordingSession?.addMarker(); markerCount = recordingSession?.markerCount ?? 0 }
    private func startTimer() {
        let start = Date()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                let value = Int(Date().timeIntervalSince(start))
                elapsedText = String(format: "%02d:%02d", value / 60, value % 60)
                refreshRecordingHealth()
            }
        }
    }
    func stopAll() async {
        flushPendingSceneAutosave()
        if isRecording { await stopRecording() }
        setSourceMonitoring(nil)
        sources.forEach(stopCapture)
        mobileDiscovery.stop()
        localRTMPReceiver.stop()
    }

    func prepareForApplicationTermination() {
        flushPendingSceneAutosave()
        localRTMPReceiver.stop()
    }

    private func rollbackRecordingStart(_ session: RecordingSession, reason: String) async {
        DiagnosticLogger.shared.log(
            .error,
            category: "recording",
            reason,
            metadata: ["operation": "rollback-start"]
        )
        recordingSession = nil
        for capture in screenCaptures.values { await capture.stop() }
        session.cancelAndRemoveFolder()
        for item in sources where item.kind == .screen || item.kind == .window { startCapture(for: item) }
        statusText = reason
    }

    private func preflightRecording(baseDir: URL, sourceSize: CGSize) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: baseDir.path) else {
            throw RecordingPreflightError.outputNotWritable
        }
        let soloID = soloAudioSourceID
        let audioCount = sources.filter {
            $0.isEnabled && !$0.isMuted && $0.kind == .microphone
                && (soloID == nil || $0.id == soloID)
        }.count + (sources.contains {
            $0.isEnabled && !$0.isMuted && ($0.kind == .screen || $0.kind == .window)
                && (soloID == nil || $0.id == soloID)
        } ? 1 : 0)
        let required = outputSettings.estimatedBytes(
            duration: 30 * 60,
            sourceSize: sourceSize,
            videoSourceCount: videoSources.filter(\.isEnabled).count,
            audioSourceCount: audioCount
        ) + 2_000_000_000
        let values = try baseDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           Int64(available) < required {
            throw RecordingPreflightError.insufficientDisk(required: required, available: Int64(available))
        }
    }

    private func refreshRecordingHealth() {
        guard let recordingSession else { return }
        let health = recordingSession.healthSnapshot
        let now = Date()
        let cpuTime = Self.processCPUTime()
        let interval = max(0.001, now.timeIntervalSince(lastHealthSampleDate))
        let cpuPercent = max(0, (cpuTime - lastHealthCPUTime) / interval * 100)
        let writeRate = max(0, Double(health.writtenBytes - lastHealthWrittenBytes) / interval)
        lastHealthSampleDate = now
        lastHealthCPUTime = cpuTime
        lastHealthWrittenBytes = health.writtenBytes
        let target = outputSettings.frameRate.rawValue
        let actual = health.effectiveFrameRate
        let fpsText = actual > 0 ? String(format: "%.1f/%d fps", actual, target) : "--/\(target) fps"
        let dropText = health.droppedBuffers > 0 ? " · 丢 \(health.droppedBuffers)" : ""
        let diskText: String
        let outputDir = outputBaseDirectory
        if let values = try? outputDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            diskText = " · 余 \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        } else {
            diskText = ""
        }
        let loadText = String(
            format: " · CPU %.0f%% · 合 %.1f ms · %@/s",
            cpuPercent,
            health.compositionMilliseconds,
            ByteCountFormatter.string(fromByteCount: Int64(writeRate), countStyle: .file)
        )
        recordingHealthText = fpsText + dropText + loadText + diskText
        recordingHealthIsWarning = health.writerFailed
            || health.droppedBuffers > 0
            || (actual > 0 && actual < Double(target) * 0.82)
        if let error = health.errorText, health.writerFailed {
            recordingHealthText = "写入异常：\(error)"
        }
    }

    private nonisolated static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func restartCameraCaptures() {
        for item in sources where item.kind == .camera && item.isEnabled {
            stopCapture(for: item)
            item.videoFormatText = "正在协商格式…"
            startCapture(for: item)
        }
    }

    private func updateVideoFormat(
        item: CaptureSourceItem,
        buffer: CMSampleBuffer,
        pixel: CVPixelBuffer
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        if let previous = lastVideoTimestamp[item.id] {
            let delta = CMTimeGetSeconds(CMTimeSubtract(timestamp, previous))
            if delta > 0.001, delta < 1 {
                let instant = 1 / delta
                let previousFPS = measuredFrameRate[item.id] ?? instant
                measuredFrameRate[item.id] = previousFPS * 0.82 + instant * 0.18
            }
        }
        lastVideoTimestamp[item.id] = timestamp
        let now = Date()
        guard now.timeIntervalSince(lastVideoFormatPublish[item.id] ?? .distantPast) >= 0.75 else { return }
        lastVideoFormatPublish[item.id] = now
        let fps = measuredFrameRate[item.id] ?? 0
        item.videoFormatText = fps > 0
            ? String(format: "%d×%d · %.1f fps", CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), fps)
            : "\(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))"
        item.observedFrameRate = fps
    }

    private func persistSources() {
        let snapshot = sources.map {
            PersistedCaptureSource(
                id: $0.id,
                kind: $0.kind,
                name: $0.name,
                // RTMP 地址可能包含推流密钥，不写入 UserDefaults。
                deviceIdentifier: $0.kind == .rtmp && !isLocalRTMPSource($0.id)
                    ? ""
                    : $0.deviceIdentifier,
                isEnabled: $0.kind == .rtmp && !isLocalRTMPSource($0.id)
                    ? false
                    : $0.isEnabled,
                recordsISO: $0.recordsISO,
                isMuted: $0.isMuted,
                gainDB: $0.gainDB
            )
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            captureSourcesJSON = String(decoding: data, as: UTF8.self)
        }
        persistedSoloAudioSourceID = soloAudioSourceID?.uuidString ?? ""
    }

    private func restoreSources() {
        guard let data = captureSourcesJSON.data(using: .utf8),
              let saved = try? JSONDecoder().decode([PersistedCaptureSource].self, from: data)
        else { return }
        var usedDevices = Set<String>()
        for value in saved {
            let deviceKey = "\(value.kind.rawValue):\(value.deviceIdentifier)"
            guard !usedDevices.contains(deviceKey) else { continue }
            usedDevices.insert(deviceKey)
            let item = CaptureSourceItem(
                id: value.id,
                kind: value.kind,
                name: value.name,
                deviceIdentifier: value.deviceIdentifier,
                isEnabled: value.isEnabled,
                recordsISO: value.recordsISO,
                isMuted: value.isMuted,
                gainDB: value.gainDB ?? 0
            )
            sources.append(item)
            if value.isEnabled { startCapture(for: item) }
        }
        let savedSolo = UUID(uuidString: persistedSoloAudioSourceID)
        soloAudioSourceID = sources.first {
            $0.id == savedSolo && $0.isEnabled
                && ($0.kind == .microphone || $0.kind == .screen || $0.kind == .window)
        }?.id
    }

    private func compositionChanged() {
        markSceneDirty()
        objectWillChange.send()
        persistCompositionLayers()
        scheduleProgramPreview(force: true)
        syncLiveComposition()
    }

    private func syncLiveComposition() {
        recordingSession?.updateComposition(
            layers: compositionLayers,
            transition: selectedTransition
        )
    }

    private func persistCompositionLayers() {
        if let data = try? JSONEncoder().encode(compositionLayers) {
            compositionLayersJSON = String(decoding: data, as: UTF8.self)
            compositionGraphVersion = 2
        }
    }

    private func restoreCompositionLayers() {
        let validSourceIDs = Set(videoSources.map(\.id))
        let saved: [CompositionLayer] = {
            guard let data = compositionLayersJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([CompositionLayer].self, from: data)) ?? []
        }()
        if compositionGraphVersion >= 2 {
            compositionLayers = saved.filter { validSourceIDs.contains($0.sourceID) }
        } else {
            compositionLayers = migrateLegacyCompositionLayers(extras: saved, validSourceIDs: validSourceIDs)
            persistCompositionLayers()
        }
        if compositionLayers.isEmpty,
           let first = videoSources.first(where: \.isEnabled) {
            compositionLayers = [CompositionLayer(sourceID: first.id, rect: .fullCanvas, displayMode: .fit)]
            for item in videoSources.filter({ $0.isEnabled && $0.id != first.id }) {
                addCompositionLayer(sourceID: item.id)
            }
            persistCompositionLayers()
        }
        if selectedCompositionLayerID == nil {
            selectedCompositionLayerID = compositionLayers.last?.id
        }
    }

    private func migrateLegacyCompositionLayers(
        extras: [CompositionLayer],
        validSourceIDs: Set<UUID>
    ) -> [CompositionLayer] {
        guard let legacyPrimary = UUID(uuidString: persistedPrimarySourceID),
              validSourceIDs.contains(legacyPrimary)
        else { return extras.filter { validSourceIDs.contains($0.sourceID) } }
        let legacyLayout = CompositionLayout(
            template: selectedTemplate,
            overlayRect: NormalizedRect(x: overlayX, y: overlayY, width: overlayWidth, height: overlayHeight),
            fillOverlay: overlayFill,
            fillPrimary: primaryFill,
            stretchPrimary: primaryStretch,
            primaryRect: NormalizedRect(x: primaryX, y: primaryY, width: primaryWidth, height: primaryHeight),
            primaryAnchorX: primaryAnchorX,
            primaryAnchorY: primaryAnchorY
        )
        var legacySceneJSON: [String: Any] = [
            "name": "迁移",
            "layout": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyLayout))) ?? [:],
            "primarySourceID": legacyPrimary.uuidString,
            "layers": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(extras))) ?? []
        ]
        if let secondary = UUID(uuidString: persistedSecondarySourceID) {
            legacySceneJSON["secondarySourceID"] = secondary.uuidString
        }
        if let data = try? JSONSerialization.data(withJSONObject: legacySceneJSON),
           let scene = try? JSONDecoder().decode(CompositionScene.self, from: data) {
            return scene.layers.filter { validSourceIDs.contains($0.sourceID) }
        }
        return extras.filter { validSourceIDs.contains($0.sourceID) }
    }

    private func persistScenes() {
        if let data = try? JSONEncoder().encode(savedScenes) {
            compositionScenesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func restoreScenes() {
        guard savedScenes.isEmpty,
              let data = compositionScenesJSON.data(using: .utf8),
              let saved = try? JSONDecoder().decode([CompositionScene].self, from: data)
        else { return }
        savedScenes = saved
        let restoredID = UUID(uuidString: persistedActiveSceneID)
        activeSceneID = savedScenes.contains(where: { $0.id == restoredID }) ? restoredID : nil
        setSceneDirty(false)
    }

    private func nextSceneName() -> String {
        var index = 1
        while savedScenes.contains(where: { $0.name == "场景 \(index)" }) { index += 1 }
        return "场景 \(index)"
    }

    private func uniqueSceneName(base: String) -> String {
        guard savedScenes.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while savedScenes.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }

    private func snapshotWithID(_ snapshot: CompositionScene, id: UUID) -> CompositionScene {
        CompositionScene(
            id: id,
            name: snapshot.name,
            layers: snapshot.layers,
            audioStates: snapshot.audioStates,
            soloAudioSourceID: snapshot.soloAudioSourceID,
            transition: snapshot.transition ?? selectedTransition,
            outputSettings: snapshot.outputSettings ?? outputSettings,
            recordingTitle: snapshot.recordingTitle ?? recordingTitle
        )
    }

    private func finishSavingScene(_ scene: CompositionScene) {
        activeSceneID = scene.id
        persistedActiveSceneID = scene.id.uuidString
        setSceneDirty(false)
        persistScenes()
        statusText = "已保存场景：\(scene.name)"
    }

    private func markSceneDirty() {
        setSceneDirty(false)
        guard !compositionLayers.isEmpty else { return }
        sceneAutosaveTask?.cancel()
        sceneAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.autoSaveCurrentScene()
        }
    }

    private func flushPendingSceneAutosave() {
        sceneAutosaveTask?.cancel()
        sceneAutosaveTask = nil
        autoSaveCurrentScene()
    }

    private func autoSaveCurrentScene() {
        guard let snapshot = currentSceneSnapshot(name: activeSceneName) else { return }
        let existing = activeSceneID.flatMap { id in savedScenes.first(where: { $0.id == id }) }
        let name = existing?.name ?? nextSceneName()
        let targetID = existing?.id ?? snapshot.id
        let updated = snapshotWithID(currentSceneSnapshot(name: name) ?? snapshot, id: targetID)
        if let index = savedScenes.firstIndex(where: { $0.id == targetID }) {
            savedScenes[index] = updated
        } else {
            savedScenes.append(updated)
        }
        activeSceneID = updated.id
        persistedActiveSceneID = updated.id.uuidString
        setSceneDirty(false)
        persistScenes()
    }

    private func setSceneDirty(_ dirty: Bool) {
        sceneHasUnsavedChanges = dirty
        persistedSceneDirty = dirty
    }
}

private enum RecordingPreflightError: LocalizedError {
    case outputNotWritable
    case insufficientDisk(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .outputNotWritable:
            return "输出目录不可写，请检查 Movies/课录 权限"
        case let .insufficientDisk(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "磁盘空间不足：预计至少需要 \(formatter.string(fromByteCount: required))，当前可用 \(formatter.string(fromByteCount: available))"
        }
    }
}
