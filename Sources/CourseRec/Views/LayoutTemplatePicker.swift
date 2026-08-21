import SwiftUI

struct LayoutTemplatePicker: View {
    @EnvironmentObject private var manager: CaptureManager
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    @State private var showsTemplates = true

    var body: some View {
        ScrollView {
            layoutInspector
                .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var layoutInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            SceneListView()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showsTemplates.toggle()
                    }
                } label: {
                    HStack {
                        Text("套用布局")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        StudioChevronGlyph()
                            .rotationEffect(.degrees(showsTemplates ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsTemplates {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(CompositionTemplate.allCases) { template in
                            templateButton(template)
                        }
                    }
                    Text("模板只排列前两个可见图层，其余图层保持不变。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            CompositionLayerListView()

            Text("录制中可以切换场景和调整图层；编码参数保持锁定。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func templateButton(_ template: CompositionTemplate) -> some View {
        let isSelected = manager.isTemplateApplied(template)
        return Button {
            manager.selectTemplate(template)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                TemplateDiagram(template: template)
                    .frame(height: 42)
                Text(template.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.red : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.red.opacity(0.055) : Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.red : Color.primary.opacity(0.13), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }

}

private struct TemplateDiagram: View {
    let template: CompositionTemplate

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                switch template {
                case .screenOnly:
                    sourceRect(bounds, tone: 0.42)
                case .cameraOnly:
                    sourceRect(
                        CGRect(
                            x: bounds.width * 0.08,
                            y: bounds.height * 0.08,
                            width: bounds.width * 0.84,
                            height: bounds.height * 0.84
                        ),
                        tone: 0.72
                    )
                case .screenCameraPip:
                    sourceRect(bounds, tone: 0.42)
                    sourceRect(
                        CGRect(x: bounds.width * 0.68, y: bounds.height * 0.58, width: bounds.width * 0.28, height: bounds.height * 0.34),
                        tone: 0.78
                    )
                case .cameraScreenPip:
                    sourceRect(bounds, tone: 0.42)
                    sourceRect(
                        CGRect(x: bounds.width * 0.04, y: bounds.height * 0.58, width: bounds.width * 0.28, height: bounds.height * 0.34),
                        tone: 0.78
                    )
                case .presenterSplit:
                    sourceRect(CGRect(x: 0, y: 0, width: bounds.width * 0.72, height: bounds.height), tone: 0.42)
                    sourceRect(CGRect(x: bounds.width * 0.72, y: 0, width: bounds.width * 0.28, height: bounds.height), tone: 0.72)
                case .equalSplit:
                    sourceRect(CGRect(x: 0, y: 0, width: bounds.width * 0.5, height: bounds.height), tone: 0.42)
                    sourceRect(CGRect(x: bounds.width * 0.5, y: 0, width: bounds.width * 0.5, height: bounds.height), tone: 0.72)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func sourceRect(_ rect: CGRect, tone: Double) -> some View {
        Rectangle()
            .fill(Color(white: tone))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .overlay(alignment: .topLeading) {
                Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
    }
}
