import SwiftUI

/// A title's motion over its time on screen: a trapezoid whose left ramp is
/// the transition in and right ramp the transition out. The diamond handles
/// at the top corners drag horizontally. All values in seconds.
struct Lifeline: View {
    let total: Double
    let inDuration: Double
    let outDuration: Double
    let onBegin: () -> Void
    let onChange: (_ inDuration: Double, _ outDuration: Double) -> Void
    let onEnd: () -> Void

    private enum Handle { case transitionIn, transitionOut }

    @State private var dragging: Handle?

    private static let height: CGFloat = 46
    private static let topY: CGFloat = 6
    private static let baseY: CGFloat = 42
    /// Horizontal room either side so a handle at an end stays inside the view.
    private static let inset: CGFloat = 7

    init(total: Double, inDuration: Double, outDuration: Double,
         onBegin: @escaping () -> Void,
         onChange: @escaping (_ inDuration: Double, _ outDuration: Double) -> Void,
         onEnd: @escaping () -> Void) {
        self.total = total
        self.inDuration = inDuration
        self.outDuration = outDuration
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
    }

    /// `inDuration` and `outDuration` clamped so each is >= 0 and they fit in `total`.
    private var ramps: (in: Double, out: Double) {
        let total = max(total, 0)
        let rampIn = min(max(inDuration, 0), total)
        return (rampIn, min(max(outDuration, 0), total - rampIn))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            envelope
            HStack {
                caption(ramps.in, "In")
                Spacer()
                caption(max(total, 0), "On screen")
                Spacer()
                caption(ramps.out, "Out")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lifeline")
        .accessibilityValue("\(seconds(ramps.in)) in, \(seconds(max(total, 0))) on screen, "
                            + "\(seconds(ramps.out)) out")
    }

    private var envelope: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.inset * 2, 1)
            let (rampIn, rampOut) = ramps
            let scale = total > 0 ? width / CGFloat(total) : 0
            let inX = Self.inset + CGFloat(rampIn) * scale
            let outX = Self.inset + width - CGFloat(rampOut) * scale
            Canvas { context, _ in
                var outline = Path()
                outline.move(to: CGPoint(x: Self.inset, y: Self.baseY))
                outline.addLine(to: CGPoint(x: inX, y: Self.topY))
                outline.addLine(to: CGPoint(x: outX, y: Self.topY))
                outline.addLine(to: CGPoint(x: Self.inset + width, y: Self.baseY))
                var fill = outline
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Instrument.neonSoft, Instrument.neon.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: Self.topY),
                    endPoint: CGPoint(x: 0, y: Self.baseY)))
                context.stroke(outline, with: .color(Instrument.neon), lineWidth: 1.5)
                for x in [inX, outX] {
                    let diamond = Path(CGRect(x: -5, y: -5, width: 10, height: 10))
                        .applying(CGAffineTransform(rotationAngle: .pi / 4)
                            .concatenating(CGAffineTransform(translationX: x, y: Self.topY)))
                    context.fill(diamond, with: .color(Instrument.top))
                    context.stroke(diamond, with: .color(Instrument.neon), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard total > 0 else { return }
                    if dragging == nil {
                        let x = drag.startLocation.x
                        // Nearer handle; on a tie the side the press is on.
                        dragging = abs(x - inX) < abs(x - outX)
                            || (abs(x - inX) == abs(x - outX) && x < inX)
                            ? .transitionIn : .transitionOut
                        onBegin()
                    }
                    let time = Double((drag.location.x - Self.inset) / scale)
                    switch dragging {
                    case .transitionIn:
                        onChange(min(max(time, 0), total - rampOut), rampOut)
                    case .transitionOut:
                        onChange(rampIn, min(max(total - time, 0), total - rampIn))
                    case nil:
                        break
                    }
                }
                .onEnded { _ in
                    guard dragging != nil else { return }
                    dragging = nil
                    onEnd()
                })
        }
        .frame(height: Self.height)
    }

    private func caption(_ value: Double, _ label: String) -> some View {
        Text("\(seconds(value)) \(label.uppercased())")
            .font(Instrument.mono(10.5))
            .foregroundStyle(Instrument.muted)
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2f S", value)
    }
}

#Preview("Lifeline") {
    @Previewable @State var ramps = (in: 0.4, out: 0.6)
    Lifeline(total: 4, inDuration: ramps.in, outDuration: ramps.out,
             onBegin: {}, onChange: { ramps = ($0, $1) }, onEnd: {})
        .padding(16)
        .frame(width: Instrument.panelWidth)
        .background(Instrument.background)
}
