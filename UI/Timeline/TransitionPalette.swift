import SwiftUI
import TitleCutCore
import UniformTypeIdentifiers

/// The badge a clip transition shows on the timeline and in the palette:
/// black or white for a dip, grey for a crossfade, with a bow-tie glyph.
enum TransitionBadge {
    static let size = CGSize(width: 20, height: 14)

    static func draw(_ kind: ClipTransitionKind, in rect: CGRect, selected: Bool,
                     context: GraphicsContext) {
        let badge = Path(roundedRect: rect, cornerRadius: 4)
        let (fill, mark): (Color, Color) = switch kind {
        case .dipToBlack: (.black, .white)
        case .dipToWhite: (.white, Theme.text)
        case .crossfade: (Theme.muted, .white)
        }
        context.fill(badge, with: .color(fill))
        let inner = rect.insetBy(dx: 5, dy: 3)
        var glyph = Path()
        glyph.move(to: CGPoint(x: inner.minX, y: inner.minY))
        glyph.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        glyph.addLine(to: CGPoint(x: inner.midX, y: inner.midY))
        glyph.closeSubpath()
        glyph.move(to: CGPoint(x: inner.maxX, y: inner.minY))
        glyph.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        glyph.addLine(to: CGPoint(x: inner.midX, y: inner.midY))
        glyph.closeSubpath()
        context.fill(glyph, with: .color(mark))
        if selected {
            context.stroke(badge, with: .color(Theme.accent), lineWidth: 2)
        } else {
            context.stroke(badge, with: .color(kind == .dipToWhite ? Theme.muted : .white),
                           lineWidth: 1)
        }
    }

    /// Drag payload for a palette tile.
    static func payload(_ kind: ClipTransitionKind) -> String { prefix + kind.rawValue }

    /// The kind a dropped string names, if it came from the palette.
    static func kind(fromPayload text: String) -> ClipTransitionKind? {
        guard text.hasPrefix(prefix) else { return nil }
        return ClipTransitionKind(rawValue: String(text.dropFirst(prefix.count)))
    }

    private static let prefix = "titlecut-transition:"
}

/// One badge as a view.
struct TransitionBadgeView: View {
    let kind: ClipTransitionKind

    var body: some View {
        Canvas { context, size in
            TransitionBadge.draw(kind, in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                                 selected: false, context: context)
        }
        .frame(width: TransitionBadge.size.width + 2, height: TransitionBadge.size.height + 2)
    }
}

/// The Transitions popover: a tile per kind, dragged onto the timeline.
struct TransitionPalette: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ClipTransitionKind.allCases, id: \.self) { kind in
                HStack(spacing: 10) {
                    TransitionBadgeView(kind: kind)
                    Text(kind.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: 190, height: 32)
                .background(Theme.ground, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .draggable(TransitionBadge.payload(kind)) {
                    HStack(spacing: 6) {
                        TransitionBadgeView(kind: kind)
                        Text(kind.name).font(.system(size: 12, weight: .medium))
                    }
                    .padding(6)
                }
                .help(kind == .crossfade
                      ? "Drag onto a cut between clips"
                      : "Drag onto a cut, or the video's start or end")
            }
            Text("Drag one onto a cut on the timeline, or right-click a cut.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .frame(width: 190, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }
}

/// Drops from `TransitionPalette` onto the timeline: the start, cut or
/// end nearest the pointer takes the transition. A crossfade dropped on the
/// video's start or end becomes a fade from or to black.
struct TransitionDrop: DropDelegate {
    let layout: TimelineLayout
    @Binding var target: TransitionPoint?
    let place: @MainActor @Sendable (TransitionPoint, ClipTransitionKind) -> Void
    /// Adds a dropped video file at the end; `nil` refuses videos.
    var dropVideo: (@MainActor @Sendable (URL) -> Void)?
    /// Inserts a dropped picture: after the segment at an output time, or at
    /// the end for `nil` (dropped off the segment track); `nil` refuses pictures.
    var dropImage: (@MainActor @Sendable (URL, Tick?) -> Void)?

    /// Points from the pointer within which a cut takes the drop.
    static let reach: CGFloat = 40

    func validateDrop(info: DropInfo) -> Bool {
        isFile(info) ? dropVideo != nil || dropImage != nil
                     : info.hasItemsConforming(to: [.plainText])
    }

    /// A file from Finder, which may also carry its path as text.
    private func isFile(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isFile(info) {
            target = nil
            return DropProposal(operation: dropVideo == nil && dropImage == nil
                                ? .forbidden : .copy)
        }
        target = layout.isInSegmentTrack(info.location)
            ? layout.nearestPoint(toX: info.location.x, within: Self.reach) : nil
        return DropProposal(operation: target == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if isFile(info) {
            target = nil
            guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
            let dropVideo = dropVideo, dropImage = dropImage
            let time: Tick? = layout.isInSegmentTrack(info.location)
                ? max(layout.tick(atX: info.location.x), 0) : nil
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
                    .contentType?.conforms(to: .image) ?? false
                Task { @MainActor in
                    if isImage { dropImage?(url, time) } else { dropVideo?(url) }
                }
            }
            return true
        }
        guard let point = target,
              let provider = info.itemProviders(for: [.plainText]).first else {
            target = nil
            return false
        }
        target = nil
        let place = place
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let kind = TransitionBadge.kind(fromPayload: text) else { return }
            Task { @MainActor in place(point, kind) }
        }
        return true
    }
}
