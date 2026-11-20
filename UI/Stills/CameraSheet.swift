import AppKit
import SwiftUI
import TitleCutCore

/// Edits a still's camera. MOVE glides from the whole frame to the END
/// box; HOLD shows the box for the whole still. Drag the box to move it,
/// drag its corner dot to zoom, down to the whole picture with bars. Each
/// drag is one undo step and shows in the preview at once.
struct CameraSheet: View {
    let store: ProjectStore
    let stillID: UUID
    /// The output size, whose shape the END box has.
    let renderSize: CGSize

    @State private var image: NSImage?
    /// The end keyframe at the press, and whether the corner is dragged.
    @State private var drag: (end: ZoomKeyframe, corner: Bool)?
    /// Ends the scroll-zoom undo step once scrolling stops.
    @State private var zoomEnd: Task<Void, Never>?
    /// The view at the start of a Control-drag of the picture.
    @State private var pan: ZoomKeyframe?
    @Environment(\.dismiss) private var dismiss

    /// Drags are measured in this fixed space, not the moving box's own.
    private static let space = "camera"
    private static let gesture = "Change Camera Motion"
    private static let maximumScale = 8.0
    private static let canvas = CGSize(width: 640, height: 480)

    /// The whole frame, where every freeze's camera starts.
    static let whole = ZoomKeyframe(time: 0, center: CGPoint(x: 0.5, y: 0.5), scale: 1,
                                    easing: .easeInOut)

    private var still: StillSegment? {
        for segment in store.project.segments {
            if case .still(let still) = segment, still.id == stillID { return still }
        }
        return nil
    }

    private var stillImage: StillImage? {
        still.flatMap { still in store.project.stills.first { $0.id == still.stillID } }
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "CAMERA",
                            trailing: isHeld ? "HOLD ONE VIEW" : "WHOLE FRAME → END")
            if let still {
                HStack(spacing: 10) {
                    ChipRow(options: [(value: false, label: "Move"), (value: true, label: "Hold")],
                            selection: isHeld) { held in setHeld(held, still: still) }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if let still, let info = stillImage {
                GeometryReader { geometry in
                    let shown = shownImage(info.pixelSize, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                            .contentShape(Rectangle())
                            .gesture(panGesture(still: still, imageSize: info.pixelSize,
                                                shown: shown))
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: shown.width, height: shown.height)
                                .offset(x: shown.minX, y: shown.minY)
                                .allowsHitTesting(false)
                        }
                        box(Self.end(of: still), still: still, imageSize: info.pixelSize,
                            shown: shown)
                    }
                }
                .coordinateSpace(.named(Self.space))
                .background(ScrollCatcher { factor in
                    zoom(by: factor, still: still, imageSize: info.pixelSize)
                })
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .background(Color.black)
            }
            HStack(spacing: 8) {
                Text("Drag the box or Control-drag the picture to move; scroll or drag the dot to zoom.")
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
                Spacer()
                Button("RESET") { store.perform(.setStillZoom(id: stillID, zoom: [])) }
                    .buttonStyle(InstrumentButtonStyle(filled: false))
                    .disabled((still?.zoom ?? []).isEmpty)
                Button("DONE") { dismiss() }
                    .buttonStyle(InstrumentButtonStyle(filled: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
        }
        .frame(width: Self.canvas.width)
        .background(Instrument.background)
        .preferredColorScheme(.light)
        .task(id: stillImage?.fileName) {
            image = stillImage.flatMap { NSImage(contentsOf: StillFiles.url(for: $0.fileName)) }
        }
        .onChange(of: still == nil) { _, gone in if gone { dismiss() } }
    }

    // MARK: Geometry

    /// Whether the camera holds one view (a single keyframe).
    private var isHeld: Bool { still?.zoom.count == 1 }

    /// Switches between one held view and a motion, keeping the END view.
    private func setHeld(_ held: Bool, still: StillSegment) {
        guard held != isHeld else { return }
        var end = Self.end(of: still)
        if held {
            end.time = 0
            store.perform(.setStillZoom(id: still.id, zoom: [end]))
        } else {
            end.time = still.duration
            store.perform(.setStillZoom(id: still.id, zoom: [Self.whole, end]))
        }
    }

    /// Where the image is drawn in `area`: fitted with room around it for
    /// the box at its smallest zoom, which can be larger than the image.
    private func shownImage(_ size: CGSize, in area: CGSize) -> CGRect {
        let fit = StillRenderer.viewRect(
            center: CGPoint(x: 0.5, y: 0.5),
            scale: StillRenderer.fitScale(imageSize: size, renderSize: renderSize),
            imageSize: size, renderSize: renderSize)
        let across = max(fit.width, 1), down = max(fit.height, 1)
        let outer = fitted(CGSize(width: size.width * across, height: size.height * down),
                           in: area)
        let width = outer.width / across, height = outer.height / down
        return CGRect(x: outer.midX - width / 2, y: outer.midY - height / 2,
                      width: width, height: height)
    }

    /// An image of `size` fitted and centred in `area`.
    private func fitted(_ size: CGSize, in area: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (area.width - width) / 2, y: (area.height - height) / 2,
                      width: width, height: height)
    }

    /// The camera's last keyframe, timed where the motion ends: before the
    /// hold, or at the freeze's end for a new motion; at 0 when held.
    static func end(of still: StillSegment) -> ZoomKeyframe {
        var end = still.zoom.last ?? whole
        end.time = still.zoom.count == 1 ? 0 : still.duration - still.hold
        return end
    }

    // MARK: Box

    private func box(_ key: ZoomKeyframe, still: StillSegment, imageSize: CGSize,
                     shown: CGRect) -> some View {
        let view = StillRenderer.viewRect(center: key.center, scale: key.scale,
                                          imageSize: imageSize, renderSize: renderSize)
        let rect = CGRect(x: shown.minX + view.minX * shown.width,
                          y: shown.minY + view.minY * shown.height,
                          width: view.width * shown.width, height: view.height * shown.height)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Instrument.neon, lineWidth: 2)
                .background(Color.white.opacity(0.001))
                .gesture(dragGesture(corner: false, still: still, imageSize: imageSize,
                                     shown: shown))
            Text("END")
                .font(Instrument.mono(10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Instrument.neon, in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
                .allowsHitTesting(false)
            Circle()
                .fill(Instrument.neon)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .position(x: rect.width, y: rect.height)
                .gesture(dragGesture(corner: true, still: still, imageSize: imageSize,
                                     shown: shown))
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    /// Writes `key` as the held view or the motion's end, inside the open
    /// undo step, with its centre where the clamped box actually is.
    private func write(_ key: ZoomKeyframe, still: StillSegment, imageSize: CGSize) {
        var key = key
        let clamped = StillRenderer.viewRect(center: key.center, scale: key.scale,
                                             imageSize: imageSize, renderSize: renderSize)
        key.center = CGPoint(x: clamped.midX, y: clamped.midY)
        store.performInGesture(.setStillZoom(
            id: still.id, zoom: still.zoom.count == 1 ? [key] : [Self.whole, key]))
    }

    /// Zooms the view by `factor` about its centre; a run of scrolling is
    /// one undo step.
    private func zoom(by factor: Double, still: StillSegment, imageSize: CGSize) {
        guard drag == nil, pan == nil else { return }
        if zoomEnd == nil { store.beginGesture(named: Self.gesture) }
        zoomEnd?.cancel()
        var key = Self.end(of: still)
        let fit = StillRenderer.fitScale(imageSize: imageSize, renderSize: renderSize)
        key.scale = min(max(key.scale * factor, fit), Self.maximumScale)
        write(key, still: still, imageSize: imageSize)
        zoomEnd = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            zoomEnd = nil
            store.endGesture()
        }
    }

    /// Control-drag on the picture moves it under the view: the view goes
    /// the other way.
    private func panGesture(still: StillSegment, imageSize: CGSize,
                            shown: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if pan == nil {
                    guard drag == nil, zoomEnd == nil,
                          !NSEvent.modifierFlags.intersection([.control, .command, .option])
                            .isEmpty else { return }
                    pan = Self.end(of: still)
                    store.beginGesture(named: Self.gesture)
                }
                guard var key = pan, shown.width > 0, shown.height > 0 else { return }
                key.center = CGPoint(x: key.center.x - value.translation.width / shown.width,
                                     y: key.center.y - value.translation.height / shown.height)
                write(key, still: still, imageSize: imageSize)
            }
            .onEnded { _ in
                guard pan != nil else { return }
                pan = nil
                store.endGesture()
            }
    }

    /// Moves the box (body) or zooms it about its centre (corner).
    private func dragGesture(corner: Bool, still: StillSegment, imageSize: CGSize,
                             shown: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard pan == nil, zoomEnd == nil else { return }
                    drag = (Self.end(of: still), corner)
                    store.beginGesture(named: Self.gesture)
                }
                guard let drag, shown.width > 0, shown.height > 0 else { return }
                var key = drag.end
                // Screen points to normalised image units.
                let dx = value.translation.width / shown.width
                let dy = value.translation.height / shown.height
                if corner {
                    let original = StillRenderer.viewRect(center: key.center, scale: key.scale,
                                                          imageSize: imageSize,
                                                          renderSize: renderSize)
                    let width = max(original.width + 2 * dx, 0.01)
                    let fit = StillRenderer.fitScale(imageSize: imageSize, renderSize: renderSize)
                    key.scale = min(max(key.scale * Double(original.width / width), fit),
                                    Self.maximumScale)
                } else {
                    key.center = CGPoint(x: key.center.x + dx, y: key.center.y + dy)
                }
                write(key, still: still, imageSize: imageSize)
            }
            .onEnded { _ in
                guard drag != nil else { return }
                drag = nil
                store.endGesture()
            }
    }
}

/// Scroll-wheel and pinch zoom over the camera canvas: reports a zoom
/// factor, above 1 to zoom in.
private struct ScrollCatcher: NSViewRepresentable {
    let onZoom: @MainActor (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var onZoom: (@MainActor (Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
                [weak self] event in
                let used = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return used ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        private func consumes(_ event: NSEvent) -> Bool {
            guard event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            if event.type == .magnify {
                onZoom?(1 + Double(event.magnification))
                return true
            }
            // A wheel notch is about one line; a trackpad reports points.
            let delta = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10)
            guard delta != 0 else { return false }
            onZoom?(exp(delta * 0.01))
            return true
        }
    }
}
