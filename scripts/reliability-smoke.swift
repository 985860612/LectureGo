import AVFoundation
import CoreVideo
import Foundation

@main
struct ReliabilitySmokeTest {
    static func main() throws {
        try verifyEstimation()
        try verifyScenePersistence()
        try verifyLegacySceneMigration()
        try verifyAudioRouting()
        try verifyTransactionalWriter()
        print("reliability-smoke: PASS")
    }

    private static func verifyAudioRouting() throws {
        let mutedScreen = RecordingSourceDefinition(
            id: UUID(), kind: .screen, name: "屏幕", deviceIdentifier: "1",
            recordsISO: true, isMuted: true, capturesSystemAudio: false
        )
        let selectedWindow = RecordingSourceDefinition(
            id: UUID(), kind: .window, name: "窗口", deviceIdentifier: "2",
            recordsISO: true, isMuted: false, capturesSystemAudio: true
        )
        let microphone = RecordingSourceDefinition(
            id: UUID(), kind: .microphone, name: "麦克风", deviceIdentifier: "3",
            recordsISO: true, isMuted: true, capturesSystemAudio: false
        )
        let mobile = RecordingSourceDefinition(
            id: UUID(), kind: .mobile, name: "移动端", deviceIdentifier: "phone",
            recordsISO: true, isMuted: false, capturesSystemAudio: false
        )
        let mobileScreen = RecordingSourceDefinition(
            id: UUID(), kind: .mobile, name: "手机屏幕", deviceIdentifier: "phone-screen",
            recordsISO: true, isMuted: false, capturesSystemAudio: true,
            mobileAudioRole: .system
        )
        let mobileCamera = RecordingSourceDefinition(
            id: UUID(), kind: .mobile, name: "手机摄像头", deviceIdentifier: "phone-camera",
            recordsISO: true, isMuted: false, capturesSystemAudio: false,
            mobileAudioRole: .microphone
        )
        let rtmp = RecordingSourceDefinition(
            id: UUID(), kind: .rtmp, name: "RTMP", deviceIdentifier: "rtmp://example/live",
            recordsISO: true, isMuted: false, capturesSystemAudio: false
        )
        let routed = [
            mutedScreen, selectedWindow, microphone, mobile, mobileScreen, mobileCamera, rtmp
        ]
            .flatMap(\.routedAudioSources)
        guard routed == [
            RoutedBufferSource(id: selectedWindow.id, media: .systemAudio),
            RoutedBufferSource(id: mobileScreen.id, media: .systemAudio),
            RoutedBufferSource(id: mobileCamera.id, media: .microphoneAudio)
        ] else {
            throw SmokeError.failed("本机与移动端的系统声/人声路由不正确")
        }
    }

    private static func verifyEstimation() throws {
        let settings = OutputVideoSettings(
            resolution: .fullHD1080,
            frameRate: .fps30,
            codec: .h264,
            bitrate: .automatic
        )
        let one = settings.estimatedBytes(
            duration: 3600,
            sourceSize: CGSize(width: 1920, height: 1080),
            videoSourceCount: 1,
            audioSourceCount: 1
        )
        let three = settings.estimatedBytes(
            duration: 3600,
            sourceSize: CGSize(width: 1920, height: 1080),
            videoSourceCount: 3,
            audioSourceCount: 2
        )
        guard three > one else { throw SmokeError.failed("空间估算未随来源数量增加") }
    }

    private static func verifyScenePersistence() throws {
        let primary = UUID()
        let secondary = UUID()
        let third = UUID()
        let layer = CompositionLayer(
            sourceID: secondary,
            rect: NormalizedRect(x: 0.12, y: 0.24, width: 0.31, height: 0.28),
            displayMode: .fit,
            isVisible: true,
            isLocked: true
        )
        let scene = CompositionScene(
            name: "讲课",
            layers: [
                CompositionLayer(
                    sourceID: primary,
                    rect: NormalizedRect(x: 0.08, y: 0.12, width: 0.81, height: 0.76),
                    displayMode: .stretch
                ),
                layer,
                CompositionLayer(
                    sourceID: third,
                    rect: NormalizedRect(x: 0.58, y: 0.12, width: 0.22, height: 0.32)
                )
            ],
            audioStates: [SceneAudioState(sourceID: UUID(), isMuted: false, recordsISO: true, gainDB: 3)],
            soloAudioSourceID: nil,
            transition: .fade300,
            outputSettings: OutputVideoSettings(
                resolution: .qhd1440,
                frameRate: .fps30,
                codec: .hevc,
                bitrate: .mbps20
            ),
            recordingTitle: "数学课"
        )
        let restored = try JSONDecoder().decode(
            CompositionScene.self,
            from: JSONEncoder().encode(scene)
        )
        guard restored.name == scene.name,
              restored.layers.count == 3,
              restored.layers[0].displayMode == .stretch,
              restored.layers[1].rect == layer.rect,
              restored.layers[1].isLocked == true,
              restored.layers[2].sourceID == third,
              restored.transition == .fade300,
              restored.outputSettings == scene.outputSettings,
              restored.recordingTitle == "数学课",
              restored.audioStates == scene.audioStates
        else { throw SmokeError.failed("场景持久化往返不一致") }
    }

    private static func verifyLegacySceneMigration() throws {
        struct LegacyScene: Codable {
            let id: UUID
            let name: String
            let layout: CompositionLayout
            let primarySourceID: UUID
            let secondarySourceID: UUID?
            let layers: [CompositionLayer]
        }
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let legacy = LegacyScene(
            id: UUID(),
            name: "旧版画中画",
            layout: CompositionLayout(
                template: .screenCameraPip,
                overlayRect: .defaultOverlay,
                fillOverlay: true,
                fillPrimary: false,
                primaryRect: .fullCanvas
            ),
            primarySourceID: first,
            secondarySourceID: second,
            layers: [CompositionLayer(sourceID: third)]
        )
        let migrated = try JSONDecoder().decode(
            CompositionScene.self,
            from: JSONEncoder().encode(legacy)
        )
        guard migrated.layers.map(\.sourceID) == [first, second, third],
              migrated.layers[0].rect == .fullCanvas,
              migrated.layers[1].rect == .defaultOverlay
        else { throw SmokeError.failed("旧版主副场景没有正确迁移为有序图层") }
    }

    private static func verifyTransactionalWriter() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("courserec-reliability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = folder.appendingPathComponent("result.mov")
        let partial = folder.appendingPathComponent("result.partial.mov")
        let writer = try TrackWriter(
            url: output,
            videoSize: (320, 180),
            videoBitRate: 1_000_000,
            videoCodec: .h264,
            expectedFrameRate: 30,
            needsPixelBufferAdaptor: true
        )
        writer.startIfNeeded(t0: .zero)
        guard let pool = writer.pixelBufferPool else { throw SmokeError.failed("像素池创建失败") }

        for index in 0 ..< 12 {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let buffer = pixel else { throw SmokeError.failed("测试帧创建失败") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(index * 4), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            while !writer.appendPixelBuffer(buffer, at: time) {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        guard FileManager.default.fileExists(atPath: partial.path),
              !FileManager.default.fileExists(atPath: output.path)
        else { throw SmokeError.failed("封盘前文件没有保持 partial 状态") }

        let semaphore = DispatchSemaphore(value: 0)
        var result: TrackWriterResult?
        writer.finish {
            result = $0
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success,
              result?.succeeded == true,
              result?.videoFrames == 12,
              FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: partial.path)
        else { throw SmokeError.failed("事务式封盘失败") }
    }
}

private enum SmokeError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case let .failed(text): return text }
    }
}
