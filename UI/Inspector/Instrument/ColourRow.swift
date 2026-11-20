import AppKit
import SwiftUI
import TitleCutCore

/// Preset swatches plus a system colour well with opacity. A swatch is one
/// choice; the colour well reports every change while the person drags.
struct ColourRow: View {
    let colour: RGBA
    /// A swatch was clicked.
    let onSelect: (RGBA) -> Void
    /// The colour well changed; called repeatedly during a drag.
    let onPick: (RGBA) -> Void

    init(colour: RGBA, onSelect: @escaping (RGBA) -> Void, onPick: @escaping (RGBA) -> Void) {
        self.colour = colour
        self.onSelect = onSelect
        self.onPick = onPick
    }

    static let presets: [(name: String, colour: RGBA)] = [
        ("White", RGBA(red: 1, green: 1, blue: 1)),
        ("Black", RGBA(red: 0, green: 0, blue: 0)),
        ("Black 60%", RGBA(red: 0, green: 0, blue: 0, alpha: 0.6)),
        ("Yellow", RGBA(red: 1, green: 0.84, blue: 0.1)),
        ("Red", RGBA(red: 0.86, green: 0.12, blue: 0.15)),
        ("Cyan", RGBA(red: 0, green: 0.9, blue: 1)),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.presets.indices, id: \.self) { index in
                let preset = Self.presets[index]
                let selected = Self.matches(preset.colour, colour)
                Button { onSelect(preset.colour) } label: {
                    swatch(preset.colour)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(selected ? Instrument.neon : Instrument.outline,
                                          lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            ColorPicker("Custom colour", selection: Binding(
                get: { Color(rgba: colour) },
                set: { onPick(RGBA($0)) }), supportsOpacity: true)
                .labelsHidden()
        }
    }

    /// A 22 pt square of `colour` over a checkerboard, so opacity shows.
    private func swatch(_ colour: RGBA) -> some View {
        Canvas { context, size in
            let cell = size.width / 4
            for row in 0..<4 {
                for column in 0..<4 where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                             width: cell, height: cell)),
                                 with: .color(Instrument.grid))
                }
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(rgba: colour)))
        }
        .frame(width: 22, height: 22)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Equal to within 8-bit rounding.
    private static func matches(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.red - b.red) < 0.004 && abs(a.green - b.green) < 0.004
            && abs(a.blue - b.blue) < 0.004 && abs(a.alpha - b.alpha) < 0.004
    }
}

extension Color {
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBA {
    /// `color` in sRGB.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}

#Preview("ColourRow") {
    @Previewable @State var colour = RGBA(red: 1, green: 1, blue: 1)
    ColourRow(colour: colour, onSelect: { colour = $0 }, onPick: { colour = $0 })
        .padding(16)
        .frame(width: Instrument.panelWidth)
        .background(Instrument.background)
}
