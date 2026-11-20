import SwiftUI

/// Where a title lands: a grid frame at the video's aspect, crosshairs and a
/// glowing ring at `position`, with X/Y percentage readouts. A drag or click
/// sets the position, clamped to 0...1. With Command or Option held, the
/// point snaps to a grid line it comes near, and to a crossing near both.
struct TargetPad: View {
    /// Title centre, normalised 0...1, origin top-left.
    let position: CGPoint
    /// Video width / height.
    let aspect: CGFloat
    let onBegin: () -> Void
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void

    @State private var isDragging = false

    private static let width: CGFloat = 128
    /// Grid cells across and down.
    private static let divisions = 4
    /// How near a grid line, in points, the drag must come to snap to it.
    private static let snapDistance: CGFloat = 6

    init(position: CGPoint, aspect: CGFloat, onBegin: @escaping () -> Void,
         onChange: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) {
        self.position = position
        self.aspect = aspect
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
    }

    private var size: CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        return CGSize(width: Self.width, height: (Self.width / ratio).rounded())
    }

    private var clamped: CGPoint {
        CGPoint(x: min(max(position.x, 0), 1), y: min(max(position.y, 0), 1))
    }

    var body: some View {
        HStack(spacing: 14) {
            pad
            VStack(alignment: .leading, spacing: 6) {
                readout("X", clamped.x)
                readout("Y", clamped.y)
            }
            .font(Instrument.mono(12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Title position")
        .accessibilityValue("X \(percent(clamped.x)), Y \(percent(clamped.y))")
    }

    private var pad: some View {
        let size = size
        let point = CGPoint(x: clamped.x * size.width, y: clamped.y * size.height)
        return Canvas { context, canvasSize in
            var grid = Path()
            for step in 1..<Self.divisions {
                let fraction = CGFloat(step) / CGFloat(Self.divisions)
                grid.move(to: CGPoint(x: fraction * canvasSize.width, y: 0))
                grid.addLine(to: CGPoint(x: fraction * canvasSize.width, y: canvasSize.height))
                grid.move(to: CGPoint(x: 0, y: fraction * canvasSize.height))
                grid.addLine(to: CGPoint(x: canvasSize.width, y: fraction * canvasSize.height))
            }
            context.stroke(grid, with: .color(Instrument.grid), lineWidth: 1)

            var cross = Path()
            cross.move(to: CGPoint(x: point.x, y: 0))
            cross.addLine(to: CGPoint(x: point.x, y: canvasSize.height))
            cross.move(to: CGPoint(x: 0, y: point.y))
            cross.addLine(to: CGPoint(x: canvasSize.width, y: point.y))
            context.stroke(cross, with: .color(Instrument.neonSoft), lineWidth: 1)

            let ring = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14,
                                              height: 14))
            var glow = context
            glow.addFilter(.shadow(color: Instrument.neon, radius: 5))
            glow.stroke(ring, with: .color(Instrument.neon), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.outline))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isDragging {
                    isDragging = true
                    onBegin()
                }
                let snaps = !NSEvent.modifierFlags.intersection([.command, .option]).isEmpty
                onChange(CGPoint(x: Self.fraction(drag.location.x, of: size.width, snaps: snaps),
                                 y: Self.fraction(drag.location.y, of: size.height, snaps: snaps)))
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                onEnd()
            })
    }

    /// `offset` across `length` as 0...1; with `snaps`, the nearest grid
    /// line's fraction when within `snapDistance` of it.
    private static func fraction(_ offset: CGFloat, of length: CGFloat, snaps: Bool) -> CGFloat {
        let value = min(max(offset / length, 0), 1)
        guard snaps else { return value }
        let line = (value * CGFloat(divisions)).rounded() / CGFloat(divisions)
        return line > 0 && line < 1 && abs(value - line) * length <= snapDistance ? line : value
    }

    private func readout(_ axis: String, _ value: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(axis).foregroundStyle(Instrument.dim)
            Text(percent(value)).foregroundStyle(Instrument.text)
        }
    }

    private func percent(_ value: CGFloat) -> String {
        String(format: "%.1f%%", Double(value) * 100)
    }
}

#Preview("TargetPad") {
    @Previewable @State var position = CGPoint(x: 0.3, y: 0.72)
    TargetPad(position: position, aspect: 16 / 9,
              onBegin: {}, onChange: { position = $0 }, onEnd: {})
        .padding(16)
        .frame(width: Instrument.panelWidth, alignment: .leading)
        .background(Instrument.background)
}
