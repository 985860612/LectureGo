import AppKit
import SwiftUI

struct OutputSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: CaptureManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StudioOutputSettingsGlyph()
                Text("输出设置")
                    .font(.headline)
                Spacer()
                if manager.isRecording {
                    Text("录制中已锁定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("关闭") { dismiss() }
                    .buttonStyle(FlatButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            settingsForm
                .disabled(manager.isRecording)

            Divider()

            Text(manager.outputSettings.estimateLabel(
                sourceSize: manager.canvasSourcePixelSize,
                videoSourceCount: manager.videoSources.filter(\.isEnabled).count,
                audioSourceCount: manager.sources.filter {
                    $0.isEnabled && !$0.isMuted && !$0.kind.isVideo
                }.count
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let warning = manager.outputCompatibilityWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程名称")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("课录", text: Binding(
                get: { manager.recordingTitle },
                set: manager.setRecordingTitle
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("输出目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(manager.outputBaseDirectory.path)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("选择") { chooseOutputDirectory() }
                    .buttonStyle(FlatButtonStyle())
            }

            Divider()

            Text("快速预设")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(OutputPreset.allCases) { preset in
                    Button(preset.label) { manager.applyOutputPreset(preset) }
                        .buttonStyle(FlatButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            settingRow("画面方向") {
                Picker("", selection: Binding(
                    get: { manager.outputSettings.orientation },
                    set: manager.setOutputOrientation
                )) {
                    ForEach(OutputOrientation.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            settingRow("分辨率") {
                Picker("", selection: Binding(
                    get: { manager.outputSettings.resolution },
                    set: manager.setOutputResolution
                )) {
                    ForEach(OutputResolution.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
            }
            settingRow("帧率") {
                Picker("", selection: Binding(
                    get: { manager.outputSettings.frameRate },
                    set: manager.setOutputFrameRate
                )) {
                    ForEach(OutputFrameRate.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
            }
            settingRow("编码") {
                Picker("", selection: Binding(
                    get: { manager.outputSettings.codec },
                    set: manager.setOutputCodec
                )) {
                    ForEach(OutputCodec.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
            }
            settingRow("码率") {
                Picker("", selection: Binding(
                    get: { manager.outputSettings.bitrate },
                    set: manager.setOutputBitrate
                )) {
                    ForEach(OutputBitrate.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
            }

            Text("画面方向、分辨率和帧率控制成片；编码与码率同时用于视频独立文件。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = manager.outputBaseDirectory
        if panel.runModal() == .OK, let url = panel.url {
            manager.setOutputBaseDirectory(url)
        }
    }

    private func settingRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
                .labelsHidden()
                .frame(width: 190, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
