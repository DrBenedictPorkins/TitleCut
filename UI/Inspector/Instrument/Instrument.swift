import SwiftUI

/// Design tokens for the "Instrument" inspector: a cockpit-like panel in
/// the app's light theme, with a cyan signal colour for live values.
enum Instrument {
    static let top = Color(hex: 0xFFFFFF)
    static let bottom = Color(hex: 0xF3F6F9)
    /// Panel ground, `top` to `bottom`.
    static let background = LinearGradient(colors: [top, bottom], startPoint: .top,
                                           endPoint: .bottom)
    static let border = Color(hex: 0xD9DDE3)
    static let divider = Color(hex: 0xE6EAEF)
    static let text = Color(hex: 0x1C2027)
    static let muted = Color(hex: 0x5B6370)
    static let dim = Color(hex: 0x8A94A3)
    static let neon = Color(hex: 0x0891B2)
    static let neonSoft = neon.opacity(0.28)
    /// Text and marks drawn on a `neon` fill.
    static let onNeon = Color.white
    /// Inset behind text fields.
    static let field = Color(hex: 0xF1F4F7)
    /// Ground behind style thumbnails, dark so white titles read.
    static let thumbnail = Color(hex: 0x2B313B)
    /// Outline of chips and the target pad frame.
    static let outline = Color(hex: 0xCBD3DC)
    /// Unfilled slider track.
    static let track = Color(hex: 0xE1E6EC)
    /// Slider tick marks.
    static let tick = Color(hex: 0xC3CBD5)
    /// Target pad grid lines.
    static let grid = Color(hex: 0xE6EBF0)

    static let panelWidth: CGFloat = 320

    /// System monospaced font.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A panel section: top divider, uppercase mono label, optional trailing
/// text button (e.g. "RESET"), then the content.
struct InstrumentSection<Content: View>: View {
    let label: String
    let trailing: String?
    let onTrailing: (() -> Void)?
    let content: Content

    init(_ label: String, trailing: String? = nil, onTrailing: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.trailing = trailing
        self.onTrailing = onTrailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Instrument.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label.uppercased())
                        .font(Instrument.mono(10))
                        .tracking(1.4)
                        .foregroundStyle(Instrument.dim)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let trailing {
                        Button(trailing.uppercased()) { onTrailing?() }
                            .buttonStyle(.plain)
                            .font(Instrument.mono(10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(Instrument.neon)
                            .disabled(onTrailing == nil)
                    }
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

#Preview("InstrumentSection") {
    VStack(spacing: 0) {
        InstrumentSection("Landing", trailing: "Reset", onTrailing: {}) {
            Text("Step 1 — Open the project")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Instrument.text)
        }
        InstrumentSection("Lifeline") {
            Text("Content").foregroundStyle(Instrument.muted)
        }
    }
    .frame(width: Instrument.panelWidth)
    .background(Instrument.background)
}
