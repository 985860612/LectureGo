import SwiftUI

struct ProgramMonitorView: View {
    @EnvironmentObject private var manager: CaptureManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("输出监看")
                    .font(.headline)
                Text("\(manager.compositionLayers.filter(\.isVisible).count) 个可见图层")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.isRecording {
                    Text(manager.recordingHealthText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(manager.recordingHealthIsWarning ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 280, alignment: .trailing)
                }
                Text(manager.outputResolutionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            GeometryReader { geometry in
                ZStack {
                    Color(white: 0.12)
                    if let frame = manager.composedFrame {
                        let canvas = aspectFitRect(
                            contentSize: CGSize(width: frame.width, height: frame.height),
                            in: geometry.size
                        )
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .frame(width: canvas.width, height: canvas.height)
                            .position(x: canvas.midX, y: canvas.midY)

                        ForEach(manager.compositionLayers.filter(\.isVisible)) { layer in
                            CompositionLayerEditor(layerID: layer.id, canvas: canvas)
                                .environmentObject(manager)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("等待输出画面")
                                .font(.headline)
                            Text("从左侧来源中加入至少一个视频图层")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }

            Divider()

            HStack {
                Text(manager.selectedLayerEditorMode == .crop
                    ? "拖动所选图层画面调整裁切位置"
                    : "单击选择图层；拖动画框改变位置，拖右下角等比例缩放")
                Spacer()
                Text("监看与成片共用合成器")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func aspectFitRect(contentSize: CGSize, in available: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let scale = min(available.width / contentSize.width, available.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct CompositionLayerEditor: View {
    @EnvironmentObject private var manager: CaptureManager
    let layerID: UUID
    let canvas: CGRect
    @State private var moveStart: NormalizedRect?
    @State private var resizeStart: NormalizedRect?
    @State private var cropStart: CGPoint?

    var body: some View {
        if let layer = manager.compositionLayer(layerID) {
            let rect = layer.rect.cgRect(in: canvas.size)
                .offsetBy(dx: canvas.minX, dy: canvas.minY)
            let selected = manager.selectedCompositionLayerID == layerID
            let cropping = selected
                && manager.selectedLayerEditorMode == .crop
                && layer.displayMode == .fill

            ZStack(alignment: .topLeading) {
                if cropping {
                    selectionRect(rect: rect, selected: selected)
                        .gesture(cropGesture)
                } else {
                    selectionRect(rect: rect, selected: selected)
                        .gesture(moveGesture(disabled: layer.isLocked))
                }

                if selected && !layer.isLocked && !cropping {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .position(x: rect.maxX - 5, y: rect.maxY - 5)
                        .gesture(resizeGesture)
                }
            }
        }
    }

    private func selectionRect(rect: CGRect, selected: Bool) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .overlay {
                Rectangle().strokeBorder(
                    selected ? Color.red : Color.white.opacity(0.42),
                    lineWidth: selected ? 1.5 : 1
                )
            }
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                manager.selectedCompositionLayerID = layerID
                manager.selectedLayerEditorMode = .frame
            }
    }

    private func moveGesture(disabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: disabled ? 10_000 : 1)
            .onChanged { value in
                manager.selectedCompositionLayerID = layerID
                if moveStart == nil { moveStart = manager.compositionLayer(layerID)?.rect }
                guard let start = moveStart, canvas.width > 0, canvas.height > 0 else { return }
                manager.updateCompositionLayer(layerID) {
                    $0.rect = NormalizedRect(
                        x: start.x + value.translation.width / canvas.width,
                        y: start.y + value.translation.height / canvas.height,
                        width: start.width,
                        height: start.height
                    )
                }
            }
            .onEnded { _ in moveStart = nil }
    }

    private var cropGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cropStart == nil, let layer = manager.compositionLayer(layerID) {
                    cropStart = CGPoint(x: layer.anchorX, y: layer.anchorY)
                }
                guard let start = cropStart,
                      let layer = manager.compositionLayer(layerID),
                      layer.rect.width > 0, layer.rect.height > 0
                else { return }
                let frameWidth = canvas.width * layer.rect.width
                let frameHeight = canvas.height * layer.rect.height
                manager.updateCompositionLayer(layerID) {
                    $0.anchorX = start.x - value.translation.width / frameWidth
                    $0.anchorY = start.y - value.translation.height / frameHeight
                }
            }
            .onEnded { _ in cropStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStart == nil {
                    manager.matchCompositionLayerToSourceAspect(layerID)
                    resizeStart = manager.compositionLayer(layerID)?.rect
                }
                guard let start = resizeStart, canvas.width > 0, canvas.height > 0 else { return }
                let startWidth = CGFloat(start.width) * canvas.width
                let startHeight = CGFloat(start.height) * canvas.height
                let diagonalSquared = startWidth * startWidth + startHeight * startHeight
                guard diagonalSquared > 0 else { return }

                let projectedDelta = (
                    value.translation.width * startWidth
                        + value.translation.height * startHeight
                ) / diagonalSquared
                let requestedScale = 1 + projectedDelta
                let minimumScale = max(0.08 / start.width, 0.08 / start.height)
                let maximumScale = min(
                    (1 - start.x) / start.width,
                    (1 - start.y) / start.height
                )
                let scale = min(maximumScale, max(minimumScale, Double(requestedScale)))

                manager.updateCompositionLayer(layerID) {
                    $0.rect = NormalizedRect(
                        x: start.x,
                        y: start.y,
                        width: start.width * scale,
                        height: start.height * scale
                    )
                }
            }
            .onEnded { _ in resizeStart = nil }
    }
}
