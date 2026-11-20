import SwiftUI

/// Tick-scale slider: label left, neon readout right, a thin track with tick
/// marks, a glowing fill and a bar-shaped knob. Drag anywhere on the track;
/// a click jumps there. Left and right arrows step by 1% when focused.
struct TickSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var isDragging = false

    /// Track height; the knob spans it.
    private static let height: CGFloat = 16
    /// Distance between tick marks.
    private static let tickSpacing: CGFloat = 10.2

    init(label: String, value: Double, range: ClosedRange<Double>,
         format: @escaping (Double) -> String,
         onBegin: @escaping () -> Void, onChange: @escaping (Double) -> Void,
         onEnd: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
    }

    private var span: Double { range.upperBound - range.lowerBound }

    private var fraction: CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .tracking(1.1)
                    .foregroundStyle(Instrument.muted)
                Spacer()
                Text(format(value))
                    .foregroundStyle(Instrument.neon)
            }
            .font(Instrument.mono(11))
            track
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = fraction * width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Instrument.track)
                    .frame(height: 2)
                    .offset(y: 7)
                Rectangle().fill(Instrument.neon)
                    .frame(width: x, height: 2)
                    .shadow(color: Instrument.neon, radius: 3)
                    .offset(y: 7)
                Canvas { context, size in
                    var ticks = Path()
                    var tickX: CGFloat = 0
                    while tickX <= size.width {
                        ticks.addRect(CGRect(x: tickX, y: 0, width: 1, height: 4))
                        tickX += Self.tickSpacing
                    }
                    context.fill(ticks, with: .color(Instrument.tick))
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Instrument.neon)
                    .frame(width: 4, height: Self.height)
                    .shadow(color: Instrument.neon, radius: 4)
                    .offset(x: x - 2)
            }
            .frame(width: width, height: Self.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        onBegin()
                    }
                    onChange(trackValue(atX: drag.location.x, width: width))
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    onEnd()
                })
        }
        .frame(height: Self.height)
    }

    private func trackValue(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let fraction = Double(min(max(x / width, 0), 1))
        return range.lowerBound + fraction * span
    }

    /// Moves by `direction` hundredths of the range, as one begin/change/end.
    private func step(_ direction: Double) {
        let next = min(max(value + direction * span / 100, range.lowerBound), range.upperBound)
        guard next != value else { return }
        onBegin()
        onChange(next)
        onEnd()
    }
}

#Preview("TickSlider") {
    @Previewable @State var size = 48.0
    @Previewable @State var duration = 4.0
    VStack(spacing: 14) {
        TickSlider(label: "Size", value: size, range: 12...120,
                   format: { "\(Int($0.rounded())) PT" },
                   onBegin: {}, onChange: { size = $0 }, onEnd: {})
        TickSlider(label: "Duration", value: duration, range: 0.5...15,
                   format: { String(format: "%.2f S", $0) },
                   onBegin: {}, onChange: { duration = $0 }, onEnd: {})
    }
    .padding(16)
    .frame(width: Instrument.panelWidth)
    .background(Instrument.background)
}
