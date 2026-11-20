import SwiftUI

/// Mono uppercase chips that wrap onto further rows. The selected chip is
/// filled neon with white text; the others are outlined.
struct ChipRow<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value?
    let onSelect: (Value) -> Void

    init(options: [(value: Value, label: String)], selection: Value?,
         onSelect: @escaping (Value) -> Void) {
        self.options = options
        self.selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button(option.label.uppercased()) { onSelect(option.value) }
                    .buttonStyle(.plain)
                    .font(Instrument.mono(10.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Instrument.onNeon : Instrument.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(selected ? Instrument.neon : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? .clear : Instrument.outline))
                    .contentShape(Rectangle())
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Left-to-right layout that wraps to a new row when out of width.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row(y: 0)]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, !last.indices.isEmpty,
               last.width + spacing + size.width > width {
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows.removeLast()
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}

#Preview("ChipRow") {
    @Previewable @State var selection = "slide"
    ChipRow(options: [("none", "None"), ("fade", "Fade"), ("slide", "Slide↑"),
                      ("scale", "Scale"), ("type", "Type"), ("cut", "Cut")],
            selection: selection, onSelect: { selection = $0 })
        .padding(16)
        .frame(width: 160)
        .background(Instrument.background)
}
