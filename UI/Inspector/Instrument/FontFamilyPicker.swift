import AppKit
import CoreText
import SwiftUI

/// The current font family as a field; clicking it opens a searchable list
/// of installed families, each name drawn in its own font.
struct FontFamilyPicker: View {
    /// Family or PostScript name, as stored in a style.
    let fontName: String
    let onSelect: (String) -> Void

    @State private var isOpen = false
    @State private var search = ""

    init(fontName: String, onSelect: @escaping (String) -> Void) {
        self.fontName = fontName
        self.onSelect = onSelect
    }

    /// The family `fontName` resolves to, as the title renderer resolves it.
    private var family: String {
        CTFontCopyFamilyName(CTFontCreateWithName(fontName as CFString, 13, nil)) as String
    }

    private var families: [String] {
        let all = NSFontManager.shared.availableFontFamilies
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button { isOpen = true } label: {
            HStack {
                Text(family)
                    .font(.custom(family, size: 14))
                    .foregroundStyle(Instrument.text)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Instrument.dim)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.outline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font")
        .accessibilityValue(family)
        .popover(isPresented: $isOpen, arrowEdge: .leading) { list }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search fonts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(families, id: \.self) { name in
                            let selected = name == family
                            Button {
                                onSelect(name)
                                isOpen = false
                            } label: {
                                Text(name)
                                    .font(.custom(name, size: 15))
                                    .foregroundStyle(selected ? Instrument.onNeon : Instrument.text)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                    .background(selected ? Instrument.neon : .clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(name)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(family, anchor: .center) }
            }
        }
        .frame(width: 260, height: 360)
        .onDisappear { search = "" }
    }
}

#Preview("FontFamilyPicker") {
    @Previewable @State var name = "Helvetica Neue"
    FontFamilyPicker(fontName: name, onSelect: { name = $0 })
        .padding(16)
        .frame(width: Instrument.panelWidth)
        .background(Instrument.background)
}
