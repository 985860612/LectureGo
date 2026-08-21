import AppKit
import ApplicationServices
import Foundation

/// 全局快捷键：⌘⇧R 启停录制、⌘⇧M 打点
/// 应用外生效需要「辅助功能」权限（首次 attach 时引导一次）；
/// 无权限时应用内快捷键仍可用（本地监视器不需要权限）。
///
/// 注意：本类刻意不标 @MainActor——NSEvent 监视器闭包是非隔离上下文，
/// Swift 6.2 运行时会动态校验 MainActor 执行器，从闭包同步调用 MainActor
/// 方法可能触发执行器校验崩溃（曾因此 SIGSEGV）。所有动作统一 Task 跳跃。
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var manager: CaptureManager?

    @MainActor
    func attach(to manager: CaptureManager) {
        guard localMonitor == nil else { return }
        self.manager = manager

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matches(event) else { return event }
            self.dispatch(event)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matches(event) else { return }
            self.dispatch(event)
        }
        requestAccessibilityOnce()
    }

    private static func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command, .shift] else { return false }
        return ["r", "m"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }

    /// 非隔离：仅从监视器闭包调用，统一跳到 MainActor 执行
    private func dispatch(_ event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased()
        Task { @MainActor in
            switch key {
            case "r":
                await manager?.toggleRecording()
            case "m":
                manager?.addMarker()
            default:
                break
            }
        }
    }

    /// 只在第一次运行时弹系统引导，避免每次启动骚扰
    @MainActor
    private func requestAccessibilityOnce() {
        guard !AXIsProcessTrusted() else { return }
        let prompted = UserDefaults.standard.bool(forKey: "didPromptAccessibility")
        guard !prompted else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        UserDefaults.standard.set(true, forKey: "didPromptAccessibility")
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
