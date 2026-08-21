import Darwin
import SwiftUI

@main
struct CourseRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var captureManager = CaptureManager()
    @State private var showsSupport = false
    private let hotkeyManager = HotkeyManager()

    var body: some Scene {
        Window("开讲 LectureGo · 多源课程录制工作台", id: "main") {
            ContentView()
                .environmentObject(captureManager)
                .frame(minWidth: 1180, minHeight: 700)
                .onAppear {
                    hotkeyManager.attach(to: captureManager)
                    appDelegate.onWillTerminate = {
                        captureManager.prepareForApplicationTermination()
                    }
                }
                .onDisappear {
                    Task { await captureManager.stopAll() }
                }
                .task { await runDebugRecordingSmokeIfRequested() }
                .sheet(isPresented: $showsSupport) {
                    SupportView()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .help) {
                Divider()
                Button("联系与支持…") {
                    showsSupport = true
                }
                Divider()
                Button("打开诊断日志目录") {
                    DiagnosticLogger.shared.openLogDirectory()
                }
            }
        }
    }

    @MainActor
    private func runDebugRecordingSmokeIfRequested() async {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["COURSE_REC_SMOKE_SECONDS"],
              let seconds = Double(raw), seconds > 0
        else { return }
        try? await Task.sleep(for: .seconds(3))
        let originalScene = captureManager.currentSceneSnapshot(name: "烟测前")
        let originalTransition = captureManager.selectedTransition
        let originalSoloSourceID = captureManager.soloAudioSourceID
        var temporarySourceID: UUID?
        let usesMultilayerLayout = ProcessInfo.processInfo.environment["COURSE_REC_SMOKE_LAYOUT"] == "multilayer"
        if usesMultilayerLayout {
            captureManager.selectTemplate(.screenCameraPip)
            captureManager.setSceneTransition(.fade600)
            let requestedWindowTitle = ProcessInfo.processInfo.environment["COURSE_REC_SMOKE_WINDOW_TITLE"]
            let window = captureManager.availableWindows().first { candidate in
                guard let requestedWindowTitle else { return true }
                return candidate.title?.localizedCaseInsensitiveContains(requestedWindowTitle) == true
            }
            if let requestedWindowTitle, window == nil {
                fputs("CourseRec smoke: WINDOW NOT FOUND \(requestedWindowTitle)\n", stderr)
                if let originalScene { captureManager.applySceneSnapshot(originalScene) }
                captureManager.setSceneTransition(originalTransition)
                captureManager.setSourceSolo(originalSoloSourceID)
                NSApplication.shared.terminate(nil)
                return
            }
            if let window {
                captureManager.addSource(.window, identifier: window.windowID.description)
                temporarySourceID = captureManager.sources.last(where: { $0.kind == .window })?.id
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let firstLayerID = captureManager.compositionLayers.first(where: \.isVisible)?.id
        switch ProcessInfo.processInfo.environment["COURSE_REC_SMOKE_PRIMARY_MODE"] {
        case "stretch":
            if let firstLayerID {
                captureManager.updateCompositionLayer(firstLayerID) {
                    $0.displayMode = .stretch
                    $0.rect = NormalizedRect(x: 0.08, y: 0.10, width: 0.72, height: 0.68)
                }
            }
        case "fill":
            if let firstLayerID {
                captureManager.updateCompositionLayer(firstLayerID) {
                    $0.displayMode = .fill
                    $0.rect = NormalizedRect(x: 0.08, y: 0.10, width: 0.72, height: 0.68)
                }
            }
        default:
            break
        }
        switch ProcessInfo.processInfo.environment["COURSE_REC_SMOKE_AUDIO_SOLO"] {
        case "microphone":
            if let microphone = captureManager.sources.first(where: { $0.kind == .microphone && $0.isEnabled }) {
                captureManager.setSourceSolo(microphone.id)
            }
        case "window":
            if let window = captureManager.sources.first(where: { $0.kind == .window && $0.isEnabled }) {
                captureManager.setSourceSolo(window.id)
            }
        default:
            break
        }
        await captureManager.toggleRecording()
        guard captureManager.isRecording else {
            fputs("CourseRec smoke: START FAILED \(captureManager.statusText)\n", stderr)
            if let temporarySourceID { captureManager.removeSource(temporarySourceID) }
            if let originalScene { captureManager.applySceneSnapshot(originalScene) }
            captureManager.setSceneTransition(originalTransition)
            captureManager.setSourceSolo(originalSoloSourceID)
            NSApplication.shared.terminate(nil)
            return
        }
        if usesMultilayerLayout {
            let firstHalf = seconds / 2
            try? await Task.sleep(for: .seconds(firstHalf))
            captureManager.selectTemplate(.presenterSplit)
            try? await Task.sleep(for: .seconds(seconds - firstHalf))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        await captureManager.toggleRecording()
        let result = captureManager.lastRecordingResult?.succeeded == true ? "PASS" : "FAIL"
        let folder = captureManager.lastRecordingFolder?.path ?? "-"
        if let temporarySourceID { captureManager.removeSource(temporarySourceID) }
        if let originalScene { captureManager.applySceneSnapshot(originalScene) }
        captureManager.setSceneTransition(originalTransition)
        captureManager.setSourceSolo(originalSoloSourceID)
        fputs("CourseRec smoke: \(result) \(captureManager.statusText) \(folder)\n", stderr)
        NSApplication.shared.terminate(nil)
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler(recordUncaughtException)
        DiagnosticLogger.shared.beginSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                DiagnosticLogger.shared.log(
                    .warning,
                    category: "lifecycle",
                    "收到终止信号",
                    metadata: ["signal": String(signalNumber)]
                )
                self?.onWillTerminate?()
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
        DiagnosticLogger.shared.endSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
