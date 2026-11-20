import SwiftUI
import TitleCutCore

/// Style tiles with live thumbnails, two or more across. The tile whose ID is
/// `selection` is outlined in neon; `badge`, when set, is printed on it.
struct StyleGrid: View {
    let styles: [TitleStyle]
    let selection: UUID?
    var columns = 2
    /// Thumbnail height in points.
    var tileHeight: CGFloat = 78
    /// Text drawn in each thumbnail.
    var sample = "Title"
    var badge: String?
    /// Right-click actions for a tile; none means no menu.
    var menu: (TitleStyle) -> [StyleMenuAction] = { _ in [] }
    let onSelect: (TitleStyle) -> Void

    @State private var thumbnails: [UUID: CGImage] = [:]
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                  spacing: 12) {
            ForEach(styles) { style in
                let actions = menu(style)
                if actions.isEmpty {
                    tile(style)
                } else {
                    tile(style).contextMenu {
                        ForEach(actions) { action in
                            Button(action.label, role: action.role, action: action.perform)
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            renderThumbnails(width: width)
        }
        .onChange(of: styles.map(\.id)) { renderThumbnails(width: nil) }
    }

    private func renderThumbnails(width: CGFloat?) {
        if let width { gridWidth = width }
        guard gridWidth > 0 else { return }
        let tileWidth = (gridWidth - CGFloat(columns - 1) * 10) / CGFloat(columns)
        // 2x the tile, for Retina.
        let size = CGSize(width: (tileWidth * 2).rounded(), height: tileHeight * 2)
        var images: [UUID: CGImage] = [:]
        for style in styles {
            if let image = StyleLibrary.thumbnail(for: style, text: sample, size: size) {
                images[style.id] = image
            }
        }
        thumbnails = images
    }

    private func tile(_ style: TitleStyle) -> some View {
        let isSelected = style.id == selection
        return Button { onSelect(style) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Instrument.thumbnail
                        .overlay {
                            if let image = thumbnails[style.id] {
                                Image(decorative: image, scale: 2)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if isSelected, let badge {
                        Text(badge)
                            .font(Instrument.mono(9, weight: .medium))
                            .foregroundStyle(Instrument.onNeon)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Instrument.neon, in: RoundedRectangle(cornerRadius: 3))
                            .padding(5)
                    }
                }
                .frame(height: tileHeight)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Instrument.neon : Instrument.border,
                                  lineWidth: isSelected ? 2.5 : 1))
                .shadow(color: isSelected ? Instrument.neonSoft : .clear, radius: 6)
                Text(style.name.uppercased())
                    .font(Instrument.mono(10.5))
                    .foregroundStyle(isSelected ? Instrument.text : Instrument.muted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One item in a style tile's right-click menu.
struct StyleMenuAction: Identifiable {
    let label: String
    var role: ButtonRole?
    let perform: () -> Void

    var id: String { label }
}
