import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: CaptureManager
    @State private var showsLocalRTMPAddress = false
    @State private var copiedLocalRTMPAddress = false
    @State private var showsOutputSettings = false
    @AppStorage("showsSourceSidebar") private var showsSourceSidebar = true
    @AppStorage("showsInspectorSidebar") private var showsInspectorSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsSourceSidebar {
                    SourceMonitorView()
                    Divider()
                }
                ProgramMonitorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsInspectorSidebar {
                    Divider()
                    LayoutTemplatePicker()
                }
            }
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsSourceSidebar.toggle()
                } label: {
                    StudioSidebarGlyph(edge: .left)
                        .foregroundStyle(showsSourceSidebar ? Color.red : Color.secondary)
                }
                .help(showsSourceSidebar ? "隐藏左侧来源栏" : "显示左侧来源栏")
                .accessibilityLabel(showsSourceSidebar ? "隐藏来源" : "显示来源")

                Button {
                    showsInspectorSidebar.toggle()
                } label: {
                    StudioSidebarGlyph(edge: .right)
                        .foregroundStyle(showsInspectorSidebar ? Color.red : Color.secondary)
                }
                .help(showsInspectorSidebar ? "隐藏右侧设置栏" : "显示右侧设置栏")
                .accessibilityLabel(showsInspectorSidebar ? "隐藏设置" : "显示设置")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(manager.isRecording ? Color.red : Color.secondary.opacity(0.55))
                .frame(width: 9, height: 9)
            Text(manager.isRecording ? "录制中  \(manager.elapsedText)" : manager.statusText)
                .font(.callout)
                .foregroundStyle(manager.isRecording ? Color.primary : Color.secondary)
                .monospacedDigit()

            Divider()
                .frame(height: 18)

            localRTMPStatusButton

            Spacer()

            outputSettingsButton

            if manager.isRecording {
                Button("打点  \(manager.markerCount)") {
                    manager.addMarker()
                }
                .buttonStyle(FlatButtonStyle())
                .help("记录分段标记（⌘⇧M）")
            }

            Button("打开输出目录") {
                let folder = manager.lastRecordingFolder
                    ?? manager.outputBaseDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            .buttonStyle(FlatButtonStyle())

            if manager.lastRecordingResult != nil {
                Button("查看录制报告") {
                    guard let folder = manager.lastRecordingFolder else { return }
                    NSWorkspace.shared.open(folder.appendingPathComponent("录制报告.txt"))
                }
                .buttonStyle(FlatButtonStyle())
            }

            if !manager.recoverablePartialFiles.isEmpty {
                Button("恢复未完成录制  \(manager.recoverablePartialFiles.count)") {
                    Task { await manager.recoverPartialRecordings() }
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(manager.isRecording)
            }

            Button {
                Task { await manager.toggleRecording() }
            } label: {
                HStack(spacing: 7) {
                    if manager.isRecording {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 12, height: 12)
                    }
                    Text(manager.isRecording ? "停止录制" : "开始录制")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(FlatButtonStyle(isPrimary: true))
            .disabled(!manager.canRecord && !manager.isRecording)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
    }

    private var outputSettingsButton: some View {
        Button {
            showsOutputSettings = true
        } label: {
            HStack(spacing: 6) {
                StudioOutputSettingsGlyph()
                Text("输出  \(outputSettingsSummary)")
                    .monospacedDigit()
            }
        }
        .buttonStyle(FlatButtonStyle())
        .help("设置输出参数")
        .sheet(isPresented: $showsOutputSettings) {
            OutputSettingsSheet()
                .environmentObject(manager)
        }
    }

    private var outputSettingsSummary: String {
        let resolution = manager.outputSettings
            .sizeLabel(source: manager.canvasSourcePixelSize)
            .replacingOccurrences(of: " ", with: "")
        return "\(resolution) · \(manager.outputSettings.frameRate.label)"
    }

    private var localRTMPStatusButton: some View {
        Button {
            showsLocalRTMPAddress.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.localRTMPIsPublishing ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text("RTMP 接收")
                    .font(.callout)
                Text(manager.localRTMPStatusText)
                    .font(.caption)
                    .foregroundStyle(manager.localRTMPIsReady ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看 RTMP 接入地址")
        .popover(isPresented: $showsLocalRTMPAddress, arrowEdge: .bottom) {
            localRTMPAddressPopover
        }
    }

    private var localRTMPAddressPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("RTMP 接入地址")
                    .font(.headline)
                Circle()
                    .fill(manager.localRTMPIsPublishing ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                Spacer()
                Text(manager.localRTMPStatusText)
                    .font(.caption)
                    .foregroundStyle(manager.localRTMPIsReady ? Color.secondary : Color.red)
            }

            Text(manager.localRTMPPublishURL)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button(copiedLocalRTMPAddress ? "已复制" : "复制接入地址") {
                    copyLocalRTMPAddress()
                }
                .buttonStyle(FlatButtonStyle(isSelected: copiedLocalRTMPAddress))
                .disabled(!manager.localRTMPIsReady || !manager.localRTMPHasLANAddress)

                Button("重新生成流名") {
                    manager.regenerateLocalRTMPStreamName()
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(manager.isRecording)
            }
        }
        .padding(12)
        .frame(width: 390)
    }

    private func copyLocalRTMPAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(manager.localRTMPPublishURL, forType: .string)
        copiedLocalRTMPAddress = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedLocalRTMPAddress = false
        }
    }
}
/// 扁平按钮：用细边框和背景区分状态，不使用阴影或大圆角。
struct FlatButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isPrimary = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isPrimary ? 16 : 9)
            .padding(.vertical, isPrimary ? 9 : 6)
            .background(backgroundColor(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foregroundColor: Color {
        if isPrimary { return .white }
        if isSelected { return .red }
        return .primary
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if isPrimary { return Color.red.opacity(pressed ? 0.78 : 1) }
        if isSelected { return Color.red.opacity(pressed ? 0.14 : 0.08) }
        return Color.primary.opacity(pressed ? 0.09 : 0.025)
    }

    private var borderColor: Color {
        if isPrimary || isSelected { return .red }
        return Color.primary.opacity(0.16)
    }
}
