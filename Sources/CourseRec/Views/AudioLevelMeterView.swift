import SwiftUI

struct AudioLevelMeterView: View {
    let average: Double
    let peak: Double
    let clipping: Bool

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                    Rectangle()
                        .fill(clipping ? Color.red : Color.primary.opacity(0.72))
                        .frame(width: geometry.size.width * average)
                    Rectangle()
                        .fill(peak > 0.92 ? Color.red : Color.primary)
                        .frame(width: 2)
                        .offset(x: max(0, geometry.size.width * peak - 2))
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 8)

            HStack {
                Text("-60")
                Spacer()
                Text("-24")
                Spacer()
                Text("-12")
                Spacer()
                Text("0 dB")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("麦克风电平")
        .accessibilityValue(clipping ? "过载" : "正常")
    }
}
