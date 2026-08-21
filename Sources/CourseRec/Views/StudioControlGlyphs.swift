import SwiftUI

/// 工作室控制区使用的轻量矢量图标，保持线性描边，不依赖图标字体。
enum StudioSidebarEdge {
    case left
    case right
}

struct StudioSidebarGlyph: View {
    let edge: StudioSidebarEdge

    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            let outline = Path(roundedRect: CGRect(
                x: 1,
                y: 1,
                width: size.width - 2,
                height: size.height - 2
            ), cornerRadius: 2)
            context.stroke(outline, with: color, lineWidth: 1.4)

            let dividerX = edge == .left ? size.width * 0.36 : size.width * 0.64
            var divider = Path()
            divider.move(to: CGPoint(x: dividerX, y: 1.5))
            divider.addLine(to: CGPoint(x: dividerX, y: size.height - 1.5))
            context.stroke(divider, with: color, lineWidth: 1.4)

            let sidebarRect: CGRect
            if edge == .left {
                sidebarRect = CGRect(
                    x: 3,
                    y: 3,
                    width: max(1, dividerX - 5),
                    height: size.height - 6
                )
            } else {
                sidebarRect = CGRect(
                    x: dividerX + 2,
                    y: 3,
                    width: max(1, size.width - dividerX - 5),
                    height: size.height - 6
                )
            }
            context.fill(Path(roundedRect: sidebarRect, cornerRadius: 1), with: color)
        }
        .frame(width: 18, height: 15)
    }
}

struct StudioPlusGlyph: View {
    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            var path = Path()
            path.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.08))
            path.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.92))
            path.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.5))
            path.addLine(to: CGPoint(x: size.width * 0.92, y: size.height * 0.5))
            context.stroke(path, with: color, lineWidth: 1.5)
        }
        .frame(width: 10, height: 10)
    }
}

struct StudioOutputSettingsGlyph: View {
    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            let rows = [0.2, 0.5, 0.8]
            let knobs = [0.34, 0.68, 0.45]

            for (row, knob) in zip(rows, knobs) {
                let y = size.height * row
                var line = Path()
                line.move(to: CGPoint(x: 1, y: y))
                line.addLine(to: CGPoint(x: size.width - 1, y: y))
                context.stroke(line, with: color, lineWidth: 1.4)

                let knobRect = CGRect(
                    x: size.width * knob - 1.5,
                    y: y - 2.2,
                    width: 3,
                    height: 4.4
                )
                context.fill(Path(roundedRect: knobRect, cornerRadius: 1), with: color)
            }
        }
        .frame(width: 16, height: 14)
    }
}

struct StudioEyeGlyph: View {
    let isVisible: Bool

    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            var eye = Path()
            eye.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.5))
            eye.addCurve(
                to: CGPoint(x: size.width * 0.92, y: size.height * 0.5),
                control1: CGPoint(x: size.width * 0.3, y: size.height * 0.12),
                control2: CGPoint(x: size.width * 0.7, y: size.height * 0.12)
            )
            eye.addCurve(
                to: CGPoint(x: size.width * 0.08, y: size.height * 0.5),
                control1: CGPoint(x: size.width * 0.7, y: size.height * 0.88),
                control2: CGPoint(x: size.width * 0.3, y: size.height * 0.88)
            )
            context.stroke(eye, with: color, lineWidth: 1.5)

            let pupil = Path(ellipseIn: CGRect(
                x: size.width * 0.4,
                y: size.height * 0.32,
                width: size.width * 0.2,
                height: size.height * 0.36
            ))
            context.stroke(pupil, with: color, lineWidth: 1.5)

            if !isVisible {
                var slash = Path()
                slash.move(to: CGPoint(x: size.width * 0.16, y: size.height * 0.12))
                slash.addLine(to: CGPoint(x: size.width * 0.84, y: size.height * 0.88))
                context.stroke(slash, with: color, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 14)
    }
}

struct StudioLockGlyph: View {
    let isLocked: Bool

    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            let body = Path(roundedRect: CGRect(
                x: size.width * 0.18,
                y: size.height * 0.42,
                width: size.width * 0.64,
                height: size.height * 0.48
            ), cornerRadius: 1.5)
            context.stroke(body, with: color, lineWidth: 1.5)

            var shackle = Path()
            shackle.move(to: CGPoint(x: size.width * 0.32, y: size.height * 0.44))
            shackle.addLine(to: CGPoint(x: size.width * 0.32, y: size.height * 0.3))
            shackle.addCurve(
                to: CGPoint(x: size.width * 0.68, y: size.height * 0.3),
                control1: CGPoint(x: size.width * 0.32, y: size.height * 0.04),
                control2: CGPoint(x: size.width * 0.68, y: size.height * 0.04)
            )
            shackle.addLine(to: CGPoint(
                x: isLocked ? size.width * 0.68 : size.width * 0.82,
                y: size.height * 0.44
            ))
            context.stroke(shackle, with: color, lineWidth: 1.5)
        }
        .frame(width: 14, height: 16)
    }
}

struct StudioMoreGlyph: View {
    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            for x in [0.2, 0.5, 0.8] {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: size.width * x - 1.2,
                        y: size.height * 0.5 - 1.2,
                        width: 2.4,
                        height: 2.4
                    )),
                    with: color
                )
            }
        }
        .frame(width: 16, height: 12)
    }
}

struct StudioChevronGlyph: View {
    var body: some View {
        Canvas { context, size in
            let color = context.resolve(.foreground)
            var path = Path()
            path.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.32))
            path.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.7))
            path.addLine(to: CGPoint(x: size.width * 0.85, y: size.height * 0.32))
            context.stroke(path, with: color, lineWidth: 1.5)
        }
        .frame(width: 12, height: 8)
    }
}
