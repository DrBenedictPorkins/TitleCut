import AVFoundation
import SwiftUI
import TitleCutCore

/// Map in the clip inspector for reframing the selected clip, as
/// Command-dragging the preview does. It shows the clip's whole
/// picture; the outlined box is what the frame shows, and the rest is
/// dimmed. A split-screen clip has two boxes, numbered: 1 is the top or left
/// half, 2 the bottom or right. Drag a box to move it, drag one of its corner
/// handles to resize it (zoom 1x to 6x, the opposite corner fixed), or click
/// elsewhere to centre the nearest box there.
struct FramingMap: View {
    let store: ProjectStore
    let player: PlayerController
    /// Every video's file, keyed as `VideoSegment.sourceID`.
    let sourceURLs: [UUID?: URL]
    /// The selected video clip.
    let target: () -> VideoSegment?
    /// What one framing fills, in render pixels: the frame, or a half.
    let framedSize: CGSize
    /// Frames the largest face in every clip; `nil` while that runs, or
    /// when no clip's picture is wider than the frame.
    let frameFaces: (() -> Void)?
    /// Frame Faces is running.
    let findingFaces: Bool
    /// The side of the square the map fits, in points.
    let width: CGFloat
    /// Side of a corner handle, in points.
    private static let handle: CGFloat = 7
    /// How far from a corner a press still takes its handle, in points; less
    /// on a small box, so its middle still moves it.
    private static let handleReach: CGFloat = 8

    /// The box being dragged: its clip, its half (`nil` for a whole clip),
    /// its rect at the press in map points, the press, and for a resize the
    /// corner that stays put.
    @State private var drag: (id: UUID, half: Int?, start: CGRect, location: CGPoint,
                              fixed: CGPoint?)?
    @State private var thumbnail: CGImage?
    /// The file `thumbnail` is a frame of.
    @State private var thumbnailURL: URL?

    /// What the map pictures: the clip's video file and upright size.
    private struct Shown {
        let url: URL
        let size: CGSize
    }

    var body: some View {
        if let clip = target(), let shown = shown(for: clip), shown.size.width > 0 {
            let sourceSize = shown.size
            // Fits a square, so a portrait picture stays small.
            let fit = width / max(sourceSize.width, sourceSize.height)
            let map = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
            let halves = shownHalves(of: clip)
            let boxes = halves.map { rect(of: framing(of: clip, half: $0), in: map,
                                          sourceSize: sourceSize) }
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                    } else {
                        Theme.segment
                    }
                    // Dims what the frame leaves out.
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)),
                                     with: .color(.black.opacity(0.6)))
                        context.blendMode = .destinationOut
                        for box in boxes {
                            context.fill(Path(box), with: .color(.black))
                        }
                    }
                    .frame(width: map.width, height: map.height)
                    ForEach(boxes.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.white, lineWidth: 2)
                            .overlay(alignment: .top) {
                                if let half = halves[index], clip.split != nil {
                                    Text("\(half + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 4)
                                        .background(Color.white)
                                }
                            }
                            .overlay { handles }
                            .frame(width: boxes[index].width, height: boxes[index].height)
                            .offset(x: boxes[index].minX, y: boxes[index].minY)
                    }
                }
                .frame(width: map.width, height: map.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            press(at: value.startLocation, clip: clip, map: map,
                                  sourceSize: sourceSize)
                        }
                        dragged(to: value.location, map: map, sourceSize: sourceSize)
                    }
                    .onEnded { _ in
                        guard drag != nil else { return }
                        drag = nil
                        store.endGesture()
                    })
                .help(clip.split == nil
                      ? "The part of this clip the frame shows. Drag to reframe; drag a "
                        + "corner to zoom."
                      : "The parts of this clip the halves show: 1 top or left, 2 bottom or "
                        + "right. Drag to reframe; drag a corner to zoom.")
                if frameFaces != nil || findingFaces {
                    Button(findingFaces ? "FINDING FACES…" : "FRAME FACES") { frameFaces?() }
                        .buttonStyle(InstrumentButtonStyle(filled: false))
                        .disabled(frameFaces == nil)
                        .help("Slide each clip sideways so its largest face is centred")
                }
            }
            .task(id: thumbnailKey(for: shown)) { await loadThumbnail(for: shown) }
        }
    }

    /// White squares inside a box's four corners.
    private var handles: some View {
        ZStack {
            let corners: [Alignment] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
            ForEach(corners.indices, id: \.self) { index in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: Self.handle, height: Self.handle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corners[index])
            }
        }
    }

    /// The halves the map shows boxes for, `nil` for a whole clip.
    private func shownHalves(of clip: VideoSegment) -> [Int?] {
        clip.split == nil ? [nil] : [0, 1]
    }

    private func framing(of clip: VideoSegment, half: Int?) -> ClipFraming {
        half.flatMap { clip.split?[$0] } ?? clip.frame
    }

    /// The clip's video, when its file and size are known.
    private func shown(for clip: VideoSegment) -> Shown? {
        guard let url = sourceURLs[clip.sourceID], let video = store.project.source(of: clip)
        else { return nil }
        return Shown(url: url, size: video.naturalSize)
    }

    /// The part of the picture `framing` shows, in map points.
    private func rect(of framing: ClipFraming, in map: CGSize, sourceSize: CGSize) -> CGRect {
        let shown = framing.visibleRect(sourceSize: sourceSize, in: framedSize)
        return CGRect(x: shown.minX * map.width, y: shown.minY * map.height,
                      width: shown.width * map.width, height: shown.height * map.height)
    }

    /// Starts a drag at `point`: on a corner handle it resizes that box, inside
    /// a box it moves it, and elsewhere it centres the nearest box there first.
    private func press(at point: CGPoint, clip: VideoSegment, map: CGSize, sourceSize: CGSize) {
        let halves = shownHalves(of: clip)
        let boxes = halves.map { rect(of: framing(of: clip, half: $0), in: map,
                                      sourceSize: sourceSize) }
        let half: (Int) -> Int? = { halves[$0] }
        for (index, box) in boxes.enumerated() {
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            let reach = min(Self.handleReach, box.width / 4, box.height / 4)
            if let corner = corners.first(where: {
                abs($0.x - point.x) <= reach && abs($0.y - point.y) <= reach
            }) {
                let fixed = CGPoint(x: corner.x == box.minX ? box.maxX : box.minX,
                                    y: corner.y == box.minY ? box.maxY : box.minY)
                drag = (clip.id, half(index), box, point, fixed)
                store.beginGesture(named: "Reframe Clip")
                return
            }
        }
        if let index = boxes.firstIndex(where: { $0.contains(point) }) {
            drag = (clip.id, half(index), boxes[index], point, nil)
            store.beginGesture(named: "Reframe Clip")
            return
        }
        // The box whose centre is nearest the press, centred on it.
        let index = boxes.indices.min {
            hypot(boxes[$0].midX - point.x, boxes[$0].midY - point.y)
                < hypot(boxes[$1].midX - point.x, boxes[$1].midY - point.y)
        } ?? 0
        let box = boxes[index]
        let centred = CGRect(x: min(max(point.x - box.width / 2, 0), map.width - box.width),
                             y: min(max(point.y - box.height / 2, 0), map.height - box.height),
                             width: box.width, height: box.height)
        drag = (clip.id, half(index), centred, point, nil)
        store.beginGesture(named: "Reframe Clip")
    }

    /// Moves or resizes the dragged box for the pointer at `location`.
    private func dragged(to location: CGPoint, map: CGSize, sourceSize: CGSize) {
        guard let drag, let clip = target(), clip.id == drag.id else { return }
        var framing = drag.half.flatMap { clip.split?[$0] } ?? clip.frame
        var box = drag.start
        if let fixed = drag.fixed {
            // The box at zoom 1; at zoom z it is 1/z that size. The pointer's
            // farther axis from the fixed corner sets the zoom.
            let unzoomed = rect(of: ClipFraming(x: framing.x, y: framing.y), in: map,
                                sourceSize: sourceSize)
            let scale = max(abs(location.x - fixed.x) / max(unzoomed.width, 1),
                            abs(location.y - fixed.y) / max(unzoomed.height, 1))
            framing.zoom = min(max(1 / max(scale, 0.001), 1), ClipFraming.maximumZoom)
            let size = CGSize(width: unzoomed.width / framing.zoom,
                              height: unzoomed.height / framing.zoom)
            box = CGRect(x: fixed.x < drag.start.midX ? fixed.x : fixed.x - size.width,
                         y: fixed.y < drag.start.midY ? fixed.y : fixed.y - size.height,
                         width: size.width, height: size.height)
        } else {
            box.origin.x += location.x - drag.location.x
            box.origin.y += location.y - drag.location.y
        }
        // Where the box sits in its travel; an axis with none keeps its value.
        let travel = CGSize(width: map.width - box.width, height: map.height - box.height)
        if travel.width > 0.5 {
            framing.x = Double(min(max(box.minX / travel.width, 0), 1))
        }
        if travel.height > 0.5 {
            framing.y = Double(min(max(box.minY / travel.height, 0), 1))
        }
        if let half = drag.half, var split = clip.split {
            split[half] = framing.clamped
            store.perform(.setSegmentSplit(id: drag.id, split: split))
        } else {
            store.perform(.setSegmentFrame(id: drag.id, frame: framing))
        }
    }

    /// The video and its time, to half a second: the playhead's while it is
    /// on the clip, else the clip's first frame.
    private func thumbnailKey(for shown: Shown) -> ThumbnailKey? {
        let half = Ticks.perSecond / 2
        guard let clip = target() else { return nil }
        var time = clip.sourceRange.start
        if let (under, sourceTime) = TimelineMath.sourcePoint(
               Ticks.from(seconds: player.currentTime), in: store.project),
           under.id == clip.id {
            time = sourceTime
        }
        return ThumbnailKey(url: shown.url, time: time / half * half)
    }

    private struct ThumbnailKey: Hashable {
        let url: URL
        let time: Tick
    }

    private func loadThumbnail(for shown: Shown) async {
        guard let key = thumbnailKey(for: shown) else { return }
        // Another video's frame would not fit the map.
        if thumbnailURL != key.url { thumbnail = nil }
        // Skips frames passed while playing or scrubbing.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: key.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width * 2, height: width * 2)
        if let image = try? await generator.image(at: Ticks.cmTime(key.time)).image,
           !Task.isCancelled {
            thumbnail = image
            thumbnailURL = key.url
        }
    }
}
