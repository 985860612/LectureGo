import AppKit
import ScreenCaptureKit
import SwiftUI

struct SourceMonitorView: View {
    @EnvironmentObject private var manager: CaptureManager
    @State private var networkSourceSheet: NetworkSourceSheet?
    @State private var showsAddSourcePopover = false
    @State private var isRefreshingSources = false
    @State private var selectedAddSourceKind = CaptureSourceKind.screen

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("来源")
                    .font(.headline)
                Text("\(visibleSources.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                addSourceButton
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleSources) { source in
                        SourceItemCard(source: source)
                            .environmentObject(manager)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(width: 326)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $networkSourceSheet) { kind in
            NetworkSourceEditor(kind: kind) { identifier in
                manager.addSource(kind.sourceKind, identifier: identifier)
            }
        }
    }

    private var visibleSources: [CaptureSourceItem] {
        manager.sources.filter {
            !manager.isLocalRTMPSource($0.id) || manager.localRTMPIsPublishing
        }
    }

    private var addSourceButton: some View {
        Button {
            if showsAddSourcePopover {
                showsAddSourcePopover = false
                return
            }
            Task {
                isRefreshingSources = true
                await manager.refreshDevices()
                isRefreshingSources = false
                showsAddSourcePopover = true
            }
        } label: {
            HStack(spacing: 4) {
                StudioPlusGlyph()
                Text(isRefreshingSources ? "刷新中" : "添加")
                    .font(.caption)
                StudioChevronGlyph()
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isRecording || isRefreshingSources)
        .help("添加来源")
        .popover(isPresented: $showsAddSourcePopover, arrowEdge: .bottom) {
            addSourcePopover
        }
    }

    private var addSourcePopover: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("来源类型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 4)

                ForEach(addSourceKinds, id: \.rawValue) { kind in
                    Button {
                        selectedAddSourceKind = kind
                    } label: {
                        HStack {
                            Text(addSourceTitle(kind))
                            Spacer(minLength: 8)
                        }
                        .font(.callout)
                        .foregroundStyle(selectedAddSourceKind == kind ? Color.red : Color.primary)
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                        .background(selectedAddSourceKind == kind ? Color.red.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 105)

            Divider()
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 7) {
                Text(addSourceTitle(selectedAddSourceKind))
                    .font(.callout.weight(.semibold))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        selectedSourceOptions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
            .frame(width: 280)
        }
        .padding(12)
        .frame(height: 260)
    }

    private var addSourceKinds: [CaptureSourceKind] {
        [.screen, .window, .camera, .mobile, .rtmp, .microphone]
    }

    private func addSourceTitle(_ kind: CaptureSourceKind) -> String {
        kind == .rtmp ? "外部 RTMP" : kind.label
    }

    @ViewBuilder
    private var selectedSourceOptions: some View {
        switch selectedAddSourceKind {
        case .screen:
            let displays = manager.availableDisplays()
            if displays.isEmpty {
                unavailableSourceText("暂无可用屏幕")
            } else {
                ForEach(displays, id: \.self) { display in
                    sourceOptionButton("显示器 \(display.displayID) · \(display.width)×\(display.height)") {
                        addSource(.screen, identifier: display.displayID.description)
                    }
                }
            }

        case .window:
            let windows = manager.availableWindows()
            if windows.isEmpty {
                unavailableSourceText("暂无可用窗口")
            } else {
                ForEach(windows, id: \.windowID) { window in
                    sourceOptionButton(windowLabel(window)) {
                        addSource(.window, identifier: window.windowID.description)
                    }
                }
            }

        case .camera:
            let cameras = manager.availableCameras()
            if cameras.isEmpty {
                unavailableSourceText("暂无可用摄像头")
            } else {
                ForEach(cameras, id: \.uniqueID) { device in
                    sourceOptionButton(device.localizedName) {
                        addSource(.camera, identifier: device.uniqueID)
                    }
                }
            }

        case .mobile:
            ForEach(manager.availableMobileStreamers()) { streamer in
                sourceOptionButton(streamer.label) {
                    addSource(.mobile, identifier: streamer.sourceIdentifier)
                }
            }
            sourceOptionButton("手动填写 IP…") {
                openNetworkSourceEditor(.mobile)
            }

        case .rtmp:
            sourceOptionButton("配置外部 RTMP…") {
                openNetworkSourceEditor(.rtmp)
            }

        case .microphone:
            let microphones = manager.availableMicrophones()
            if microphones.isEmpty {
                unavailableSourceText("暂无可用麦克风")
            } else {
                ForEach(microphones, id: \.uniqueID) { device in
                    sourceOptionButton(device.localizedName) {
                        addSource(.microphone, identifier: device.uniqueID)
                    }
                }
            }
        }
    }

    private func sourceOptionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unavailableSourceText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
    }

    private func addSource(_ kind: CaptureSourceKind, identifier: String) {
        manager.addSource(kind, identifier: identifier)
        showsAddSourcePopover = false
    }

    private func openNetworkSourceEditor(_ sheet: NetworkSourceSheet) {
        showsAddSourcePopover = false
        networkSourceSheet = sheet
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "应用"
        return "\(app) · \(window.title ?? "窗口")"
    }
}

private struct SourceItemCard: View {
    @EnvironmentObject private var manager: CaptureManager
    @ObservedObject var source: CaptureSourceItem
    @State private var editingName = false
    @State private var draftName = ""
    @State private var rtmpDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if editingName {
                    TextField("来源名称", text: $draftName, onCommit: commitName)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                } else {
                    Text(source.name)
                        .font(.callout.weight(.semibold))
                        .onTapGesture(count: 2) {
                            draftName = source.name
                            editingName = true
                        }
                }
                if manager.isLocalRTMPSource(source.id) { roleTag("内置") }
                Spacer()
                if !manager.isLocalRTMPSource(source.id) {
                    Button(source.isEnabled ? "停用" : "启用") {
                        manager.setSourceEnabled(source.id, enabled: !source.isEnabled)
                    }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(manager.isRecording)
                    Button("移除") { manager.removeSource(source.id) }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(manager.isRecording)
                }
            }

            if source.kind.isVideo {
                ZStack {
                    Color.black
                    if let frame = source.frame {
                        Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text(source.errorText ?? "等待画面")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .bottomLeading) {
                    if !source.videoFormatText.isEmpty {
                        Text(source.videoFormatText)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.86))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.64))
                    }
                }

                HStack(spacing: 6) {
                    if let layer = manager.compositionLayer(forSource: source.id) {
                        Button("选中输出图层") { manager.selectedCompositionLayerID = layer.id }
                            .buttonStyle(FlatButtonStyle(isSelected: manager.selectedCompositionLayerID == layer.id))
                        Button("从输出移除") { manager.removeCompositionLayer(layer.id) }
                            .buttonStyle(FlatButtonStyle())
                    } else {
                        Button("加入输出") { manager.addCompositionLayer(sourceID: source.id) }
                            .buttonStyle(FlatButtonStyle())
                            .disabled(!source.isEnabled)
                    }
                    Spacer()
                }
            } else {
                AudioLevelMeterView(average: source.averageLevel, peak: source.peakLevel, clipping: source.isClipping)
            }

            if manager.isLocalRTMPSource(source.id) {
                Text("自动监听 · \(manager.localRTMPStreamName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                devicePicker
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button(source.recordsISO ? "录制独立轨" : "不录独立轨") {
                        manager.setSourceRecordsISO(source.id, enabled: !source.recordsISO)
                    }
                    .buttonStyle(FlatButtonStyle(isSelected: source.recordsISO))
                    if source.kind == .microphone || source.kind == .screen || source.kind == .window {
                        Button(source.isMuted ? "已静音" : "参与成片声音") {
                            manager.setSourceMuted(source.id, muted: !source.isMuted)
                        }
                        .buttonStyle(FlatButtonStyle(isSelected: source.isMuted))
                    }
                    Spacer()
                }
                .disabled(manager.isRecording || !source.isEnabled)
                if source.kind == .microphone || source.kind == .screen || source.kind == .window {
                    HStack(spacing: 6) {
                        Button(manager.soloAudioSourceID == source.id ? "取消 Solo" : "Solo") {
                            manager.toggleSourceSolo(source.id)
                        }
                        .buttonStyle(FlatButtonStyle(isSelected: manager.soloAudioSourceID == source.id))
                        .disabled(manager.isRecording || !source.isEnabled)
                        Button(manager.monitoredAudioSourceID == source.id ? "停止监听" : "耳机监听") {
                            manager.toggleSourceMonitoring(source.id)
                        }
                        .buttonStyle(FlatButtonStyle(isSelected: manager.monitoredAudioSourceID == source.id))
                        .disabled(!source.isEnabled)
                        Spacer()
                    }
                }
            }

            if source.kind == .microphone {
                HStack(spacing: 8) {
                    Text("增益")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { source.gainDB },
                        set: { manager.setSourceGain(source.id, gainDB: $0) }
                    )) {
                        ForEach([-12.0, -6.0, 0.0, 6.0, 12.0], id: \.self) { value in
                            Text(String(format: "%+.0f dB", value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if manager.monitoredAudioSourceID == source.id {
                Text("监听已开启，建议佩戴耳机，避免扬声器回授。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
            }

            if let error = source.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(
                        manager.isLocalRTMPSource(source.id) && manager.localRTMPIsReady
                            ? Color.secondary
                            : Color.red
                    )
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.13), lineWidth: 1) }
    }

    private func commitName() {
        manager.renameSource(source.id, name: draftName)
        editingName = false
    }

    @ViewBuilder
    private var devicePicker: some View {
        let binding = Binding(
            get: { source.deviceIdentifier },
            set: { manager.updateDevice(for: source.id, identifier: $0) }
        )
        switch source.kind {
        case .screen:
            Picker("", selection: binding) {
                ForEach(manager.availableDisplays(excluding: source.id), id: \.self) { display in
                    Text("显示器 \(display.displayID) · \(display.width)×\(display.height)").tag(display.displayID.description)
                }
            }.labelsHidden()
        case .window:
            Picker("", selection: binding) {
                ForEach(manager.availableWindows(excluding: source.id), id: \.windowID) { window in
                    Text("\(window.owningApplication?.applicationName ?? "应用") · \(window.title ?? "窗口")")
                        .tag(window.windowID.description)
                }
            }.labelsHidden()
        case .camera:
            Picker("", selection: binding) {
                ForEach(manager.availableCameras(excluding: source.id), id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
            }.labelsHidden()
        case .mobile:
            Picker("", selection: binding) {
                if let current = MobileStreamer(sourceIdentifier: source.deviceIdentifier) {
                    Text(current.label).tag(current.sourceIdentifier)
                }
                ForEach(manager.availableMobileStreamers(excluding: source.id).filter {
                    $0.sourceIdentifier != source.deviceIdentifier
                }) { streamer in
                    Text(streamer.label).tag(streamer.sourceIdentifier)
                }
            }.labelsHidden()
        case .rtmp:
            HStack(spacing: 6) {
                TextField("rtmp://服务器/app/stream", text: $rtmpDraft)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { rtmpDraft = source.deviceIdentifier }
                    .onSubmit { reconnectRTMP() }
                Button("连接") { reconnectRTMP() }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(rtmpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .microphone:
            Picker("", selection: binding) {
                ForEach(manager.availableMicrophones(excluding: source.id), id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
            }.labelsHidden()
        }
    }

    private func reconnectRTMP() {
        manager.updateDevice(
            for: source.id,
            identifier: rtmpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func roleTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.red)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 2).stroke(Color.red.opacity(0.7), lineWidth: 1) }
    }
}

private enum NetworkSourceSheet: String, Identifiable {
    case mobile
    case rtmp

    var id: String { rawValue }
    var sourceKind: CaptureSourceKind { self == .mobile ? .mobile : .rtmp }
    var title: String { self == .mobile ? "添加移动端来源" : "添加 RTMP 来源" }
    var placeholder: String {
        self == .mobile ? "手机 IP，例如 192.168.1.20" : "rtmp://服务器/app/stream"
    }
}

private struct NetworkSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let kind: NetworkSourceSheet
    let onAdd: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title)
                .font(.headline)
            TextField(kind.placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if kind == .rtmp {
                Text("地址可能包含密钥，仅用于本次运行，不会写入偏好设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("使用 AndroidScreenMonitor 默认控制端口 6060。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(FlatButtonStyle())
                Button("添加") { add() }
                    .buttonStyle(FlatButtonStyle(isPrimary: true))
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func add() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if kind == .mobile {
            onAdd(MobileStreamer(
                name: "手动移动端",
                host: trimmed,
                controlPort: MobileWire.defaultControlPort
            ).sourceIdentifier)
        } else {
            onAdd(trimmed)
        }
        dismiss()
    }
}
