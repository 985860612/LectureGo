import SwiftUI
import UniformTypeIdentifiers

struct CompositionLayerListView: View {
    @EnvironmentObject private var manager: CaptureManager
    @State private var draggedLayerID: UUID?
    @State private var showsLayers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showsLayers.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("图层")
                            .font(.callout.weight(.semibold))
                        Text("\(manager.compositionLayers.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        StudioChevronGlyph()
                            .rotationEffect(.degrees(showsLayers ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                addLayerMenu
            }

            if showsLayers {
                if manager.compositionLayers.isEmpty {
                    Text("从左侧来源卡片或这里把视频加入场景")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.compositionLayers) { layer in
                        layerRow(layer)
                            .opacity(draggedLayerID == layer.id ? 0.55 : 1)
                            .onDrop(
                                of: [UTType.text],
                                delegate: CompositionLayerDropDelegate(
                                    targetLayerID: layer.id,
                                    draggedLayerID: $draggedLayerID,
                                    manager: manager
                                )
                            )
                    }
                }
            }

            if let layer = manager.compositionLayer(manager.selectedCompositionLayerID) {
                Divider()
                SelectedLayerInspector(layer: layer)
            }
        }
    }

    private var addLayerMenu: some View {
        Menu {
            ForEach(manager.availableCompositionLayerSources) { source in
                Button(source.name) { manager.addCompositionLayer(sourceID: source.id) }
            }
        } label: {
            HStack(spacing: 4) {
                StudioPlusGlyph()
                Text("添加")
                    .font(.caption)
                StudioChevronGlyph()
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(manager.availableCompositionLayerSources.isEmpty)
        .help("添加图层")
    }

    private func layerRow(_ layer: CompositionLayer) -> some View {
        let selected = manager.selectedCompositionLayerID == layer.id
        return HStack(spacing: 5) {
            dragHandle(for: layer.id)

            Button {
                manager.selectedCompositionLayerID = layer.id
            } label: {
                Text(manager.source(layer.sourceID)?.name ?? "来源已断开")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                manager.updateCompositionLayer(layer.id) { $0.isVisible.toggle() }
            } label: {
                StudioEyeGlyph(isVisible: layer.isVisible)
                    .accessibilityLabel(layer.isVisible ? "隐藏图层" : "显示图层")
            }
            .buttonStyle(StudioIconButtonStyle(isActive: layer.isVisible))
            .help(layer.isVisible ? "隐藏图层" : "显示图层")

            Button {
                manager.updateCompositionLayer(layer.id) { $0.isLocked.toggle() }
            } label: {
                StudioLockGlyph(isLocked: layer.isLocked)
                    .accessibilityLabel(layer.isLocked ? "解锁图层" : "锁定图层")
            }
            .buttonStyle(StudioIconButtonStyle(isActive: layer.isLocked))
            .help(layer.isLocked ? "解锁图层" : "锁定图层")

            Menu {
                Button("移除图层", role: .destructive) {
                    manager.removeCompositionLayer(layer.id)
                }
            } label: {
                StudioMoreGlyph()
                    .accessibilityLabel("图层操作")
            }
            .menuStyle(.button)
            .buttonStyle(StudioIconButtonStyle())
            .help("图层操作")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(selected ? Color.red.opacity(0.055) : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? Color.red : Color.primary.opacity(0.13), lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { manager.selectedCompositionLayerID = layer.id }
    }

    private func dragHandle(for layerID: UUID) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().fill(Color.secondary).frame(width: 3, height: 3)
                    Circle().fill(Color.secondary).frame(width: 3, height: 3)
                }
            }
        }
        .frame(width: 18, height: 28)
        .contentShape(Rectangle())
        .help("拖动调整图层顺序")
        .onDrag {
            draggedLayerID = layerID
            manager.selectedCompositionLayerID = layerID
            return NSItemProvider(object: layerID.uuidString as NSString)
        }
    }
}

private struct SelectedLayerInspector: View {
    @EnvironmentObject private var manager: CaptureManager
    @State private var showsInspector = true
    let layer: CompositionLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showsInspector.toggle()
                }
            } label: {
                HStack {
                    Text("所选图层")
                        .font(.callout.weight(.semibold))
                    Text(manager.source(layer.sourceID)?.name ?? "来源已断开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if layer.isLocked {
                        Text("已锁定")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    StudioChevronGlyph()
                        .rotationEffect(.degrees(showsInspector ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsInspector {
                inspectorRow("预设大小") {
                    HStack(spacing: 4) {
                        ForEach(LayerSizePreset.allCases) { preset in
                            Button(preset.label) {
                                manager.applyCompositionLayerSizePreset(preset, to: layer.id)
                            }
                            .buttonStyle(FlatButtonStyle(isSelected: isSelected(preset)))
                        }
                    }
                }

                inspectorRow("预设位置") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            positionButton(.topLeft)
                            positionButton(.center)
                            positionButton(.topRight)
                        }
                        HStack(spacing: 4) {
                            positionButton(.bottomLeft)
                            positionButton(.bottomRight)
                        }
                    }
                }

                Text("也可以在输出监看中拖动图层，或从右下角等比例缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(layer.isLocked)
    }

    private func inspectorRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func positionButton(_ preset: LayerPositionPreset) -> some View {
        Button(preset.label) {
            manager.applyCompositionLayerPositionPreset(preset, to: layer.id)
        }
        .buttonStyle(FlatButtonStyle(
            isSelected: LayerPositionPreset.matching(layer.rect) == preset
        ))
    }

    private func isSelected(_ preset: LayerSizePreset) -> Bool {
        abs(max(layer.rect.width, layer.rect.height) - preset.rawValue) <= 0.015
    }
}

private struct StudioIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : (isActive ? 0.055 : 0.02)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct CompositionLayerDropDelegate: DropDelegate {
    let targetLayerID: UUID
    @Binding var draggedLayerID: UUID?
    let manager: CaptureManager

    func dropEntered(info: DropInfo) {
        guard let draggedLayerID, draggedLayerID != targetLayerID else { return }
        manager.moveCompositionLayer(draggedLayerID, over: targetLayerID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedLayerID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard info.hasItemsConforming(to: [UTType.text]) else {
            draggedLayerID = nil
            return
        }
    }
}
