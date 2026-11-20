import AppKit
import SwiftUI
import TitleCutCore

/// Geometry of the timeline tracks, shared by drawing and hit-testing.
struct TimelineLayout {
    static let inset: CGFloat = 14
    /// Width of the lane tabs at the left of the title lanes, and the gap
    /// after them.
    static let tabWidth: CGFloat = 22
    static let tabGap: CGFloat = 6
    /// Where the tracks start: after the inset and the lane tabs.
    static let leading: CGFloat = inset + tabWidth + tabGap
    static let rulerHeight: CGFloat = 22
    static let laneHeight: CGFloat = 26
    static let laneSpacing: CGFloat = 4
    static let trackSpacing: CGFloat = 8
    static let segmentTrackHeight: CGFloat = 44
    /// Visual gap drawn at each cut between segment blocks.
    static let segmentGap: CGFloat = 3
    /// Width of the grab zone at each end of a title pill or video segment block.
    static let edgeZone: CGFloat = 6
    /// Distance within which a moved clip or dragged edge snaps.
    static let snapDistance: CGFloat = 8

    let project: Project
    let width: CGFloat
    let total: Tick
    let lanes: [UUID: Int]
    let laneCount: Int
    /// Ticks per point; 0 for an empty timeline.
    let ticksPerPoint: Double
    /// Output time at the track's left edge.
    let start: Double

    /// Room below the segment track for the scroll indicator.
    static let indicatorSpace: CGFloat = 8

    /// - Parameter view: The zoom and scroll, or `nil` to fit the whole timeline.
    init(project: Project, width: CGFloat, view: (ticksPerPoint: Double, start: Double)? = nil) {
        self.project = project
        self.width = max(width - Self.inset - Self.leading, 1)
        total = TimelineMath.outputDuration(project)
        lanes = TimelineMath.titleLanes(project)
        laneCount = max((lanes.values.max() ?? -1) + 1, 1)
        ticksPerPoint = view?.ticksPerPoint
            ?? TimelineViewport.fitTicksPerPoint(total: total, width: Double(self.width))
        start = view?.start ?? 0
    }

    /// The width given to `init`, less the inset and the lane tabs, as the
    /// viewport sees it.
    static func trackWidth(_ width: CGFloat) -> Double {
        Double(max(width - inset - leading, 1))
    }

    var titleTrackY: CGFloat { Self.rulerHeight + Self.trackSpacing }
    var titleTrackHeight: CGFloat {
        CGFloat(laneCount) * Self.laneHeight + CGFloat(laneCount - 1) * Self.laneSpacing
    }
    var segmentY: CGFloat { titleTrackY + titleTrackHeight + Self.trackSpacing }
    static let musicTrackHeight: CGFloat = 26
    var musicY: CGFloat { segmentY + Self.segmentTrackHeight + Self.trackSpacing }
    var height: CGFloat { musicY + Self.musicTrackHeight + Self.indicatorSpace }
    /// Points per tick.
    var scale: CGFloat { ticksPerPoint > 0 ? CGFloat(1 / ticksPerPoint) : 0 }

    func x(for tick: Tick) -> CGFloat { x(forTime: Double(tick)) }

    func x(forTime time: Double) -> CGFloat {
        Self.leading + CGFloat((time - start) / max(ticksPerPoint, .leastNonzeroMagnitude))
    }

    func tick(atX x: CGFloat) -> Tick {
        guard total > 0, ticksPerPoint > 0 else { return 0 }
        let tick = Tick((start + Double(x - Self.leading) * ticksPerPoint).rounded())
        return min(max(tick, 0), total)
    }

    func titleRect(_ title: Title) -> CGRect? {
        guard let range = TimelineMath.titleOutputRange(title, in: project), range.duration > 0,
              let lane = lanes[title.id] else { return nil }
        let y = titleTrackY + CGFloat(lane) * (Self.laneHeight + Self.laneSpacing)
        return CGRect(x: x(for: range.start), y: y,
                      width: max(x(for: range.end) - x(for: range.start), 4),
                      height: Self.laneHeight)
    }

    enum TitlePart { case body, leadingEdge, trailingEdge }

    /// The topmost title pill under `point`, and which part of it.
    func titleHit(at point: CGPoint) -> (Title, TitlePart)? {
        for title in project.titles.reversed() {
            guard let rect = titleRect(title), rect.insetBy(dx: -2, dy: 0).contains(point) else {
                continue
            }
            let zone = min(Self.edgeZone, rect.width / 3)
            if point.x <= rect.minX + zone { return (title, .leadingEdge) }
            if point.x >= rect.maxX - zone { return (title, .trailingEdge) }
            return (title, .body)
        }
        return nil
    }

    func musicRect(_ clip: MusicClip) -> CGRect {
        CGRect(x: x(for: clip.start), y: musicY,
               width: max(x(for: clip.end) - x(for: clip.start), 4),
               height: Self.musicTrackHeight)
    }

    /// The music piece under `point`, and which part of it.
    func musicHit(at point: CGPoint) -> (MusicClip, TitlePart)? {
        guard point.y >= musicY, point.y < musicY + Self.musicTrackHeight else { return nil }
        for clip in project.music {
            let rect = musicRect(clip)
            guard rect.insetBy(dx: -2, dy: 0).contains(point) else { continue }
            let zone = min(Self.edgeZone, rect.width / 3)
            if point.x <= rect.minX + zone { return (clip, .leadingEdge) }
            if point.x >= rect.maxX - zone { return (clip, .trailingEdge) }
            return (clip, .body)
        }
        return nil
    }

    func isInMusicTrack(_ point: CGPoint) -> Bool {
        point.y >= musicY && point.y < musicY + Self.musicTrackHeight
    }

    enum SegmentEdge { case leading, trailing }

    /// The video segment edge under `point`. At a cut between clips, the half
    /// of the zone left of the cut is the earlier clip's trailing edge; next to
    /// a gap or a track end, the clip's edge takes the whole zone.
    func segmentEdgeHit(at point: CGPoint) -> (VideoSegment, SegmentEdge)? {
        guard isInSegmentTrack(point) else { return nil }
        let segments = project.segments
        var cursor: Tick = 0
        for (index, segment) in segments.enumerated() {
            let x0 = x(for: cursor)
            let x1 = x(for: cursor + segment.duration)
            cursor += segment.duration
            guard case .video(let video) = segment else { continue }
            let zone = min(Self.edgeZone, (x1 - x0) / 3)
            let outsideBefore = index == 0 || segments[index - 1].isGap ? Self.edgeZone : 0
            let outsideAfter = index == segments.count - 1 || segments[index + 1].isGap
                ? Self.edgeZone : 0
            if point.x >= x0 - outsideBefore, point.x <= x0 + zone { return (video, .leading) }
            if point.x >= x1 - zone, point.x < x1 + outsideAfter { return (video, .trailing) }
        }
        return nil
    }

    /// The edge of a freeze or title card under `point`, with the same zones
    /// as `segmentEdgeHit`: the segment's ID and length, and which edge.
    func stillEdgeHit(at point: CGPoint) -> (id: UUID, duration: Tick, edge: SegmentEdge)? {
        guard isInSegmentTrack(point) else { return nil }
        let segments = project.segments
        var cursor: Tick = 0
        for (index, segment) in segments.enumerated() {
            let x0 = x(for: cursor)
            let x1 = x(for: cursor + segment.duration)
            cursor += segment.duration
            switch segment {
            case .still, .card: break
            case .video, .gap: continue
            }
            let zone = min(Self.edgeZone, (x1 - x0) / 3)
            let outsideBefore = index == 0 || segments[index - 1].isGap ? Self.edgeZone : 0
            let outsideAfter = index == segments.count - 1 || segments[index + 1].isGap
                ? Self.edgeZone : 0
            if point.x >= x0 - outsideBefore, point.x <= x0 + zone {
                return (segment.id, segment.duration, .leading)
            }
            if point.x >= x1 - zone, point.x < x1 + outsideAfter {
                return (segment.id, segment.duration, .trailing)
            }
        }
        return nil
    }

    /// The clip (not gap) under `point` in the segment track, and its output start.
    func clipHit(at point: CGPoint) -> (Segment, start: Tick)? {
        guard isInSegmentTrack(point) else { return nil }
        var cursor: Tick = 0
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard point.x >= x(for: cursor), point.x < x(for: cursor + segment.duration) else {
                continue
            }
            return segment.isGap ? nil : (segment, cursor)
        }
        return nil
    }

    func isInSegmentTrack(_ point: CGPoint) -> Bool {
        point.y >= segmentY && point.y < segmentY + Self.segmentTrackHeight
    }

    // MARK: Clip transitions

    /// The video's start, each cut and the end, with their output times.
    var transitionPoints: [(point: TransitionPoint, time: Tick)] {
        var points: [(point: TransitionPoint, time: Tick)] = []
        var cursor: Tick = 0
        for segment in project.segments {
            points.append((.before(segment.id), cursor))
            cursor += segment.duration
        }
        if !project.segments.isEmpty { points.append((.end, cursor)) }
        return points
    }

    /// Where the badge for a transition at `point` goes: across the top of
    /// the segment track, centred on a cut, inside the track at the start
    /// and the end.
    func badgeRect(_ point: TransitionPoint, at time: Tick) -> CGRect {
        let size = TransitionBadge.size
        let x = x(for: time)
        let minX = switch point {
        case .end: x - size.width - 3
        case .before where time == 0: x + 3
        case .before: x - size.width / 2
        }
        return CGRect(x: minX, y: segmentY + 4, width: size.width, height: size.height)
    }

    /// Every transition with its kind and badge.
    func transitionBadges() -> [(point: TransitionPoint, kind: ClipTransitionKind, rect: CGRect)] {
        transitionPoints.compactMap { point, time in
            point.transition(in: project).map { (point, $0.kind, badgeRect(point, at: time)) }
        }
    }

    /// The transition whose badge is under `point`.
    func transitionHit(at point: CGPoint) -> TransitionPoint? {
        transitionBadges().first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.point
    }

    /// The start, cut or end nearest `x`, if within `distance` points.
    func nearestPoint(toX x: CGFloat, within distance: CGFloat) -> TransitionPoint? {
        transitionPoints
            .map { (point: $0.point, distance: abs(self.x(for: $0.time) - x)) }
            .filter { $0.distance <= distance }
            .min { $0.distance < $1.distance }?.point
    }
}

/// Full-width timeline card: toolbar, ruler, title lanes, segment track (§7.3).
struct TimelineView: View {
    let store: ProjectStore
    let player: PlayerController
    /// Adds a title at the playhead with the default style.
    let addTitle: () -> Void
    /// Deletes the selected titles, or else the selected segment.
    let deleteSelection: () -> Void
    /// Opens the Auto-Captions sheet; `nil` when it cannot run.
    let autoCaptions: (() -> Void)?
    /// Opens the Remove Silences sheet; `nil` when it cannot run.
    let removeSilences: (() -> Void)?
    /// Opens the Remove Filler Words sheet; `nil` when it cannot run.
    let removeFillers: (() -> Void)?
    /// Asks for a song and adds it at the playhead; `nil` when there is no video.
    let addMusic: (() -> Void)?
    /// Asks for a video and adds it at the end; `nil` when there is no
    /// video yet or one is missing.
    let addVideo: (() -> Void)?
    /// Adds the video file dropped on the tracks at the end; `nil` as for `addVideo`.
    let dropVideo: (@MainActor @Sendable (URL) -> Void)?
    /// Inserts a dropped picture as a still after the segment at an output
    /// time, or at the end for `nil`.
    var dropImage: (@MainActor @Sendable (URL, Tick?) -> Void)? = nil
    /// Freezes the frame at the playhead; `nil` without a source video. The
    /// button is off outside a video clip.
    let freezeFrame: (() -> Void)?
    /// Inserts a title card at the playhead; `nil` on an empty timeline.
    let insertCard: (() -> Void)?
    /// Copy, Paste and Duplicate for the selection, as in the Edit menu.
    let editActions: PreviewEditActions
    /// Opens the camera window of a frozen frame (double-click).
    let editCamera: (UUID) -> Void
    /// Changes when this window copies something, so Paste appears.
    let clipboardRevision: Int
    /// Each video's audio peaks, keyed by `VideoSegment.sourceID`, drawn in
    /// the lower half of its clips' blocks.
    var waveforms: [UUID?: Waveform] = [:]

    @State private var drag: DragState?
    /// Press-time scale and scroll, held while a clip, edge or title is
    /// dragged; auto-scroll moves its start.
    @State private var frozenView: (ticksPerPoint: Double, start: Double)?
    /// Scrolls the frozen view while the pointer is held past a track edge.
    @State private var autoScroll: Task<Void, Never>?
    /// The latest drag event, replayed as the view auto-scrolls.
    @State private var lastDragValue: DragGesture.Value?
    @State private var viewport = TimelineViewport()
    /// Track width in points, for zooming from the menu.
    @State private var trackWidth: Double = 0
    /// The cursor pushed over the tracks, if any.
    @State private var shownCursor: NSCursor?
    /// The pointer over the tracks, for cursor changes on modifier keys.
    @State private var hoverPoint: CGPoint?
    /// The cut under the pointer when it was last over the segment track,
    /// for the right-click menu. Kept while the pointer is on the menu.
    @State private var menuPoint: TransitionPoint?
    /// The cut a palette drag would drop on.
    @State private var dropTarget: TransitionPoint?
    @State private var showsTransitions = false

    /// An in-progress press or drag on the tracks.
    private struct DragState {
        enum Target {
            case title(id: UUID, part: TimelineLayout.TitlePart, start: Tick, duration: Tick,
                       additive: Bool, snapPoints: [Tick])
            /// `range` is the source range and `edgeTime` the edge's output
            /// time at the press.
            case segmentEdge(id: UUID, edge: TimelineLayout.SegmentEdge, range: TickRange,
                             edgeTime: Tick, snapPoints: [Tick])
            /// A freeze's or title card's edge: either end changes its length.
            case stillEdge(id: UUID, edge: TimelineLayout.SegmentEdge, duration: Tick,
                           snapPoints: [Tick], edgeTime: Tick)
            /// `start` is the clip's output start at the press.
            case clip(id: UUID, start: Tick, duration: Tick, snapPoints: [Tick])
            /// An Option-drag: the clip and everything after it move
            /// together. `start` is the clip's output start at the press;
            /// `gapID` names a gap the move opens before it.
            case shift(id: UUID, start: Tick, gapID: UUID)
            /// `clip` as it was at the press.
            case music(clip: MusicClip, part: TimelineLayout.TitlePart, snapPoints: [Tick])
            /// A transition's badge; a click selects it.
            case transition(TransitionPoint)
            case scrub
        }
        var target: Target
        var isDragging = false
        /// Output time snapped to, drawn as a guide line.
        var snappedTo: Tick?
        /// Where the moved clip follows the pointer.
        var ghostStart: Tick?
        /// Ticks the view has auto-scrolled since the press; added to the
        /// pointer's travel.
        var scrolled: Double = 0
    }

    private var hasSelection: Bool {
        !store.selectedTitleIDs.isEmpty || store.selectedSegmentID != nil
            || store.selectedMusicID != nil || store.selectedTransition != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.border).frame(height: 1)
            tracks
                .padding(.vertical, 10)
        }
        .card()
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            addMenu
            Button { showsTransitions.toggle() } label: {
                Label("Transitions", systemImage: "square.split.diagonal")
            }
            .buttonStyle(BorderedShellButtonStyle())
            .disabled(store.project.segments.isEmpty)
            .help("Transitions to drag onto cuts, the start or the end")
            .popover(isPresented: $showsTransitions, arrowEdge: .bottom) { TransitionPalette() }
            Button("Split") { split() }
                .buttonStyle(BorderedShellButtonStyle())
                .disabled(store.project.segments.isEmpty || !player.hasMedia)
                .help("Split at playhead (Command-K)")
            Button("Auto-Captions") { autoCaptions?() }
                .buttonStyle(BorderedShellButtonStyle())
                .disabled(autoCaptions == nil)
                .help("Make captions from the video's speech")
            removeMenu
            contextualButtons
            Spacer()
            Text("Audio follows video")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.trailing, 4)
            Button { zoom(by: 1 / Self.zoomStep) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(BorderedShellButtonStyle())
            .disabled(!zoomActions.canZoomOut)
            .help("Zoom out (Command-Minus)")
            .accessibilityLabel("Zoom Out")
            Button { zoom(by: Self.zoomStep) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(BorderedShellButtonStyle())
            .disabled(!zoomActions.canZoomIn)
            .help("Zoom in (Command-Plus)")
            .accessibilityLabel("Zoom In")
            Button("Fit") { zoomToFit() }
                .buttonStyle(BorderedShellButtonStyle())
                .disabled(viewport.isFit)
                .help("Zoom to fit the whole timeline (Command-0)")
        }
        .padding(.horizontal, TimelineLayout.inset)
        .frame(height: 48)
    }

    /// Buttons for the current selection and clipboard, after a divider;
    /// none show when nothing applies.
    @ViewBuilder private var contextualButtons: some View {
        let _ = clipboardRevision
        let canCopy = editActions.canCopy()
        let canDuplicate = editActions.canDuplicate()
        let canPaste = editActions.canPaste()
        if canCopy || canDuplicate || canPaste || hasSelection {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 4)
            if canCopy {
                Button("Copy", action: editActions.copy)
                    .buttonStyle(BorderedShellButtonStyle())
                    .help("Copy the selection (Command-C)")
            }
            if canDuplicate {
                Button("Duplicate", action: editActions.duplicate)
                    .buttonStyle(BorderedShellButtonStyle())
                    .help("Duplicate the selection right after itself (Command-D)")
            }
            if canPaste {
                Button("Paste", action: editActions.paste)
                    .buttonStyle(BorderedShellButtonStyle())
                    .help("Paste at the playhead (Command-V)")
            }
            if hasSelection {
                Button("Delete", action: deleteSelection)
                    .buttonStyle(BorderedShellButtonStyle())
                    .help("Delete the selection (Delete)")
            }
        }
    }

    private func split() {
        store.perform(.splitSegment(atOutputTime: Ticks.from(seconds: player.currentTime),
                                    newSegmentID: UUID()))
    }

    // MARK: Zoom

    /// Factor for one zoom step from the toolbar or menu.
    static let zoomStep = 2.0

    private var frameRate: Double { store.project.output.frameRate }
    private var total: Tick { TimelineMath.outputDuration(store.project) }

    /// The view to draw: the press-time one during a clip or edge drag,
    /// otherwise the viewport resolved for the current timeline.
    private func view(width: Double) -> (ticksPerPoint: Double, start: Double) {
        if let frozenView { return frozenView }
        return (viewport.resolvedTicksPerPoint(total: total, width: width, frameRate: frameRate),
                viewport.resolvedStart(total: total, width: width, frameRate: frameRate))
    }

    private var zoomActions: TimelineZoomActions {
        let width = trackWidth
        let current = viewport.resolvedTicksPerPoint(total: total, width: width,
                                                     frameRate: frameRate)
        let closest = min(TimelineViewport.minimumTicksPerPoint(frameRate: frameRate),
                          TimelineViewport.fitTicksPerPoint(total: total, width: width))
        return TimelineZoomActions(
            zoomIn: { zoom(by: Self.zoomStep) }, zoomOut: { zoom(by: 1 / Self.zoomStep) },
            zoomToFit: zoomToFit,
            canZoomIn: total > 0 && width > 0 && current > closest,
            canZoomOut: !viewport.isFit)
    }

    /// Zooms anchored at the playhead, keeping it where it is on screen, or
    /// centring it if it is off screen.
    private func zoom(by factor: Double) {
        guard drag == nil, trackWidth > 0 else { return }
        let playhead = Double(Ticks.from(seconds: player.currentTime))
        let current = view(width: trackWidth)
        var x = (playhead - current.start) / max(current.ticksPerPoint, .leastNonzeroMagnitude)
        if x < 0 || x > trackWidth { x = trackWidth / 2 }
        viewport.zoom(by: factor, anchorTick: playhead, anchorX: x, total: total,
                      width: trackWidth, frameRate: frameRate)
    }

    private func zoomToFit() {
        guard drag == nil else { return }
        viewport.zoomToFit()
    }

    /// Trackpad pinch, anchored at the pointer (`x` in track coordinates).
    private func magnify(by magnification: Double, atX x: CGFloat, layout: TimelineLayout) {
        guard drag == nil, layout.total > 0 else { return }
        let anchorX = Double(x - TimelineLayout.leading)
        viewport.zoom(by: 1 + magnification,
                      anchorTick: layout.start + anchorX * layout.ticksPerPoint,
                      anchorX: anchorX, total: layout.total,
                      width: Double(layout.width), frameRate: frameRate)
    }

    /// Two-finger swipe or Shift-scroll. Returns whether the timeline scrolled.
    private func scroll(byPoints points: Double, layout: TimelineLayout) -> Bool {
        guard drag == nil, !viewport.isFit else { return false }
        viewport.scroll(byPoints: points, total: layout.total, width: Double(layout.width),
                        frameRate: frameRate)
        return true
    }

    /// Pages the view during playback so the playhead stays visible.
    private func followPlayhead() {
        guard player.isPlaying, drag == nil, !viewport.isFit, trackWidth > 0 else { return }
        viewport.reveal(Double(Ticks.from(seconds: player.currentTime)), total: total,
                        width: trackWidth, frameRate: frameRate)
    }

    // MARK: Tracks

    private var tracks: some View {
        let project = store.project
        let probe = TimelineLayout(project: project, width: 100)

        return GeometryReader { geometry in
            let layout = TimelineLayout(
                project: project, width: geometry.size.width,
                view: view(width: TimelineLayout.trackWidth(geometry.size.width)))
            ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(layout, in: context, size: size)
            }
            .background(TimelineEventCatcher(
                onScroll: { points in scroll(byPoints: points, layout: layout) },
                onMagnify: { magnification, x in magnify(by: magnification, atX: x, layout: layout) },
                onModifiersChanged: { updateCursor(layout: layout) }))
            .contentShape(Rectangle())
            .onContinuousHover { phase in hoverChanged(phase, layout: layout) }
            .contextMenu { transitionMenu(layout: layout) }
            .onDrop(of: [.plainText, .fileURL], delegate: TransitionDrop(
                layout: layout, target: $dropTarget,
                place: { [store] point, kind in Self.place(kind, at: point, store: store) },
                dropVideo: dropVideo, dropImage: dropImage))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragChanged(value, layout: layout) }
                .onEnded { value in dragEnded(value, layout: layout) })
            laneButtons(layout)
            }
        }
        .frame(height: probe.height)
        .clipped()
        .onGeometryChange(for: Double.self) { TimelineLayout.trackWidth($0.size.width) } action: {
            trackWidth = $0
        }
        .onChange(of: player.currentTime) { followPlayhead() }
        .focusedSceneValue(\.timelineZoom, zoomActions)
        .onDisappear { setCursor(nil) }
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(project.segments.count) segments, \(project.titles.count) titles")
    }

    /// A numbered tab at the left of each title lane that has titles, the
    /// lane's height. A click selects every title in the lane; Shift-click
    /// adds them.
    private func laneButtons(_ layout: TimelineLayout) -> some View {
        let ids = Dictionary(grouping: layout.lanes.keys) { layout.lanes[$0] ?? 0 }
        return ForEach(ids.keys.sorted(), id: \.self) { lane in
            let members = Set(ids[lane] ?? [])
            let selected = members.isSubset(of: store.selectedTitleIDs)
            Button {
                if NSEvent.modifierFlags.contains(.shift) {
                    store.selectedTitleIDs.formUnion(members)
                } else {
                    store.selectedTitleIDs = members
                }
            } label: {
                Text("\(lane + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(selected ? Theme.onAccent : Theme.muted)
                    .frame(width: TimelineLayout.tabWidth, height: TimelineLayout.laneHeight)
                    .background(selected ? Theme.accent : Theme.ground,
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.clear : Theme.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select every title in this lane; Shift-click adds them")
            .accessibilityLabel("Select titles in lane \(lane + 1)")
            .offset(x: TimelineLayout.inset, y: layout.titleTrackY
                + CGFloat(lane) * (TimelineLayout.laneHeight + TimelineLayout.laneSpacing))
        }
    }

    // MARK: Drawing

    private func draw(_ layout: TimelineLayout, in context: GraphicsContext, size: CGSize) {
        let inset = TimelineLayout.leading
        let selectedSegment = store.selectedSegmentID
        let selectedTitles = store.selectedTitleIDs
        var trimmedSegment: UUID?
        if let drag, drag.isDragging, case let .segmentEdge(id, _, _, _, _) = drag.target {
            trimmedSegment = id
        }

        // Title lanes background.
        for lane in 0..<layout.laneCount {
            let y = layout.titleTrackY
                + CGFloat(lane) * (TimelineLayout.laneHeight + TimelineLayout.laneSpacing)
            let rect = CGRect(x: inset, y: y, width: layout.width,
                              height: TimelineLayout.laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: TimelineLayout.laneHeight / 2),
                         with: .color(Theme.ground))
        }

        guard layout.total > 0 else {
            let empty = CGRect(x: inset, y: layout.segmentY, width: layout.width,
                               height: TimelineLayout.segmentTrackHeight)
            context.fill(Path(roundedRect: empty, cornerRadius: 8), with: .color(Theme.ground))
            return
        }

        drawScrollIndicator(context, layout: layout)
        // Content scrolled past either end stays inside the track.
        var context = context
        context.clip(to: Path(CGRect(x: inset, y: 0, width: layout.width, height: size.height)))
        drawRuler(context, layout: layout)

        // Segments.
        var cursor: Tick = 0
        let segments = layout.project.segments
        let videoKeys = layout.project.sourcesByKey.map(\.key)
        for (index, segment) in segments.enumerated() {
            let x0 = layout.x(for: cursor)
            let x1 = layout.x(for: cursor + segment.duration)
            let leftGap = index == 0 ? 0 : TimelineLayout.segmentGap / 2
            let rightGap = index == segments.count - 1 ? 0 : TimelineLayout.segmentGap / 2
            let rect = CGRect(x: x0 + leftGap, y: layout.segmentY,
                              width: max(x1 - x0 - leftGap - rightGap, 1),
                              height: TimelineLayout.segmentTrackHeight)
            let path = Path(roundedRect: rect, cornerRadius: 6)
            switch segment {
            case .video(let video):
                let videoIndex = videoKeys.firstIndex(of: video.sourceID) ?? 0
                context.fill(path, with: .color(Theme.videoClip(videoIndex)))
                if let waveform = waveforms[video.sourceID] {
                    drawWaveform(waveform, source: video.sourceRange, rate: video.rate, in: rect,
                                 layout: layout, context: context)
                }
                if video.split != nil {
                    drawSplitMark(in: rect, stacked: SplitScreen.isStacked(
                        layout.project.output.size), context: context)
                }
                if video.rate != 1 {
                    drawTag(String(format: "%g\u{00D7}", video.rate), leading: false,
                            in: rect, context: context)
                }
            case .still(let still):
                context.fill(path, with: .color(Theme.freeze))
                var labelled = context
                labelled.clip(to: Path(rect.insetBy(dx: 6, dy: 0)))
                let label = Text(still.zoom.count > 1 ? "Freeze · motion" : "Freeze")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                labelled.draw(label, at: CGPoint(x: rect.minX + 8, y: rect.minY + 12),
                              anchor: .leading)
                if still.hold > 0 {
                    drawHoldMark(at: layout.x(for: cursor + still.duration - still.hold),
                                 in: rect, context: context)
                }
            case .card(let card):
                let fill = Color(.sRGB, red: card.color.red, green: card.color.green,
                                 blue: card.color.blue, opacity: card.color.alpha)
                context.fill(path, with: .color(.black))
                context.fill(path, with: .color(fill))
                context.stroke(path, with: .color(Theme.border), lineWidth: 1)
                let light = 0.299 * card.color.red + 0.587 * card.color.green
                    + 0.114 * card.color.blue
                var labelled = context
                labelled.clip(to: Path(rect.insetBy(dx: 6, dy: 0)))
                let label = Text("Card")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(light * card.color.alpha > 0.6 ? Color.black : Color.white)
                labelled.draw(label, at: CGPoint(x: rect.minX + 8, y: rect.minY + 12),
                              anchor: .leading)
            case .gap: drawHatching(in: rect, context: context)
            }
            if segment.id == selectedSegment {
                context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
            }
            if segment.id == trimmedSegment {
                // Live length while an edge is dragged.
                let length = Text(Timecode.string(seconds: Ticks.seconds(segment.duration),
                                                  frameRate: layout.project.output.frameRate))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onAccent)
                var clipped = context
                clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 0)))
                clipped.draw(length, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
            cursor += segment.duration
        }

        // The moved clip, following the pointer.
        if let drag, drag.isDragging, let ghostStart = drag.ghostStart,
           case let .clip(_, _, duration, _) = drag.target {
            let rect = CGRect(x: layout.x(for: ghostStart), y: layout.segmentY,
                              width: max(layout.x(for: ghostStart + duration)
                                         - layout.x(for: ghostStart), 1),
                              height: TimelineLayout.segmentTrackHeight)
            let ghost = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(ghost, with: .color(Theme.accent.opacity(0.18)))
            context.stroke(ghost, with: .color(Theme.accent), lineWidth: 2)
        }

        // Clip transitions, and where a palette drag would drop one.
        for badge in layout.transitionBadges() {
            TransitionBadge.draw(badge.kind, in: badge.rect,
                                 selected: badge.point == store.selectedTransition,
                                 context: context)
        }
        if let dropTarget, let time = layout.transitionPoints.first(where: {
            $0.point == dropTarget })?.time {
            let x = layout.x(for: time)
            var line = Path()
            line.move(to: CGPoint(x: x, y: layout.segmentY - 2))
            line.addLine(to: CGPoint(x: x, y: layout.segmentY + TimelineLayout.segmentTrackHeight + 2))
            context.stroke(line, with: .color(Theme.accent), lineWidth: 3)
        }

        // Music lane and pieces.
        let musicLane = CGRect(x: TimelineLayout.leading, y: layout.musicY, width: layout.width,
                               height: TimelineLayout.musicTrackHeight)
        context.fill(Path(roundedRect: musicLane, cornerRadius: 6), with: .color(Theme.ground))
        if layout.project.music.isEmpty {
            context.draw(Text("Music").font(.system(size: 11)).foregroundStyle(Theme.muted),
                         at: CGPoint(x: TimelineLayout.leading + 10, y: musicLane.midY),
                         anchor: .leading)
        }
        for clip in layout.project.music {
            drawMusic(clip, layout: layout, selected: clip.id == store.selectedMusicID,
                      context: context)
        }

        // Snap guide.
        if let snappedTo = drag?.snappedTo {
            let x = layout.x(for: snappedTo)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: TimelineLayout.rulerHeight))
            guide.addLine(to: CGPoint(x: x, y: layout.height))
            context.stroke(guide, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
        }

        // Title pills.
        for title in layout.project.titles {
            guard let rect = layout.titleRect(title) else { continue }
            let selected = selectedTitles.contains(title.id)
            let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            if selected {
                context.fill(pill, with: .color(Theme.accent))
            } else {
                context.fill(pill, with: .color(Theme.selectedTint))
                context.stroke(pill, with: .color(Theme.titleBlockBorder), lineWidth: 1)
            }
            let firstLine = title.text.split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let label = Text(firstLine.isEmpty ? " " : firstLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Theme.onAccent : Theme.selectedText)
            var clipped = context
            clipped.clip(to: Path(rect.insetBy(dx: 8, dy: 0)))
            clipped.draw(label, at: CGPoint(x: rect.minX + 10, y: rect.midY), anchor: .leading)
        }

        // Playhead.
        let x = layout.x(for: Ticks.from(seconds: player.currentTime))
        var line = Path()
        line.move(to: CGPoint(x: x, y: 2))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Theme.accent), lineWidth: 2)
        var head = Path()
        head.move(to: CGPoint(x: x - 5, y: 0))
        head.addLine(to: CGPoint(x: x + 5, y: 0))
        head.addLine(to: CGPoint(x: x, y: 7))
        head.closeSubpath()
        context.fill(head, with: .color(Theme.accent))
    }

    /// A music piece: a green block with its song name, and its fades as
    /// ramps along the top.
    private func drawMusic(_ clip: MusicClip, layout: TimelineLayout, selected: Bool,
                           context: GraphicsContext) {
        let rect = layout.musicRect(clip)
        let block = Path(roundedRect: rect, cornerRadius: 6)
        context.fill(block, with: .color(Theme.music))
        var inner = context
        inner.clip(to: block)
        // Volume envelope: fade in, level, fade out, scaled by volume.
        let top = rect.minY + 3, bottom = rect.maxY - 3
        let level = bottom - (bottom - top) * CGFloat(clip.volume)
        var envelope = Path()
        envelope.move(to: CGPoint(x: rect.minX, y: bottom))
        envelope.addLine(to: CGPoint(x: layout.x(for: clip.start + clip.fadeIn), y: level))
        envelope.addLine(to: CGPoint(x: layout.x(for: clip.end - clip.fadeOut), y: level))
        envelope.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        envelope.closeSubpath()
        inner.fill(envelope, with: .color(.white.opacity(0.18)))
        inner.clip(to: Path(rect.insetBy(dx: 8, dy: 0)))
        inner.draw(Text(clip.name).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white),
                   at: CGPoint(x: rect.minX + 10, y: rect.midY), anchor: .leading)
        if selected {
            context.stroke(block, with: .color(Theme.accent), lineWidth: 2)
        }
    }

    /// Marks a split-screen clip: a dashed line between the halves (across
    /// the block when they are stacked, down its middle when side by side)
    /// and a "Split" tag.
    private func drawSplitMark(in rect: CGRect, stacked: Bool, context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(roundedRect: rect, cornerRadius: 6))
        var line = Path()
        if stacked {
            line.move(to: CGPoint(x: rect.minX, y: rect.midY))
            line.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        } else {
            line.move(to: CGPoint(x: rect.midX, y: rect.minY))
            line.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        clipped.stroke(line, with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        drawTag("Split", leading: true, in: rect, context: context)
    }

    /// A dashed line down a freeze block where its camera motion ends and the
    /// hold on its last view begins.
    private func drawHoldMark(at x: CGFloat, in rect: CGRect, context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(roundedRect: rect, cornerRadius: 6))
        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        clipped.stroke(line, with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    /// A small pill in a top corner of a block: "Split" at the left, a
    /// changed speed ("0.5×", "2×") at the right. Left out on a block
    /// narrower than 40 points.
    private func drawTag(_ text: String, leading: Bool, in rect: CGRect,
                         context: GraphicsContext) {
        guard rect.width > 40 else { return }
        var clipped = context
        clipped.clip(to: Path(roundedRect: rect, cornerRadius: 6))
        let tag = Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
        let resolved = clipped.resolve(tag)
        let size = resolved.measure(in: rect.size)
        let width = size.width + 8
        let pill = CGRect(x: leading ? rect.minX + 4 : rect.maxX - 4 - width, y: rect.minY + 3,
                          width: width, height: size.height + 2)
        clipped.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(.black.opacity(0.45)))
        clipped.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    /// Audio peaks in the lower half of a video block, mirrored about its
    /// centre line, one bar per point.
    private func drawWaveform(_ waveform: Waveform, source: TickRange, rate: Double,
                              in rect: CGRect,
                              layout: TimelineLayout, context: GraphicsContext) {
        let band = CGRect(x: rect.minX, y: rect.midY, width: rect.width,
                          height: rect.height / 2).insetBy(dx: 0, dy: 2)
        let visible = band.intersection(CGRect(x: TimelineLayout.leading, y: band.minY,
                                               width: layout.width, height: band.height))
        guard !visible.isNull, visible.width >= 1, layout.ticksPerPoint > 0 else { return }

        var context = context
        context.clip(to: Path(roundedRect: rect, cornerRadius: 6))
        context.fill(Path(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1)),
                     with: .color(.white.opacity(0.12)))

        // Source seconds under one point: more at a faster speed.
        let pointSeconds = layout.ticksPerPoint / Double(Ticks.timescale) * rate
        let sourceStart = Ticks.seconds(source.start)
        var bars = Path()
        var x = visible.minX.rounded(.down)
        while x < visible.maxX {
            let from = sourceStart + Double(x - rect.minX) * pointSeconds
            let peak = CGFloat(waveform.peak(fromSeconds: from,
                                             toSeconds: from + pointSeconds))
            let half = max(peak * band.height / 2, 0.5)
            bars.addRect(CGRect(x: x, y: band.midY - half, width: 1, height: half * 2))
            x += 1
        }
        context.fill(bars, with: .color(.white.opacity(0.55)))
    }

    /// Empty space: diagonal hatching inside a hairline outline.
    private func drawHatching(in rect: CGRect, context: GraphicsContext) {
        let outline = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
        var clipped = context
        clipped.clip(to: outline)
        var hatch = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            hatch.move(to: CGPoint(x: x, y: rect.maxY))
            hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        clipped.stroke(hatch, with: .color(Theme.border), lineWidth: 1)
        context.stroke(outline, with: .color(Theme.border), lineWidth: 1)
    }

    /// Thin bar under the segment track showing the visible part, when zoomed.
    private func drawScrollIndicator(_ context: GraphicsContext, layout: TimelineLayout) {
        let shown = Double(layout.width) * layout.ticksPerPoint
        guard layout.total > 0, shown < Double(layout.total) else { return }
        let y = layout.musicY + TimelineLayout.musicTrackHeight + 4
        let track = CGRect(x: TimelineLayout.leading, y: y, width: layout.width, height: 3)
        context.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(Theme.ground))
        let total = Double(layout.total)
        let thumb = CGRect(x: track.minX + track.width * CGFloat(layout.start / total), y: y,
                           width: max(track.width * CGFloat(shown / total), 12), height: 3)
        context.fill(Path(roundedRect: thumb, cornerRadius: 1.5), with: .color(Theme.muted))
    }

    /// Ticks with labels at a spacing that suits the zoom (frames, seconds,
    /// minutes), never closer than 56 pt.
    private func drawRuler(_ context: GraphicsContext, layout: TimelineLayout) {
        let inset = TimelineLayout.leading
        let rulerHeight = TimelineLayout.rulerHeight
        let frameRate = layout.project.output.frameRate
        let step = TimelineViewport.rulerStep(ticksPerPoint: layout.ticksPerPoint,
                                              frameRate: frameRate)
        // Past the end of the timeline when the scale is held during a drag.
        let end = layout.start + Double(layout.width) * layout.ticksPerPoint
        var index = (layout.start / step).rounded(.up)
        while index * step <= end + 0.0001 {
            let t = index * step
            index += 1
            let x = layout.x(forTime: t)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerHeight - 6))
            tick.addLine(to: CGPoint(x: x, y: rulerHeight))
            context.stroke(tick, with: .color(Theme.border), lineWidth: 1)
            let label = Text(TimelineViewport.rulerLabel(t, step: step, frameRate: frameRate))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.muted)
            // Keep the last label inside the track.
            let resolved = context.resolve(label)
            let labelWidth = resolved.measure(in: CGSize(width: 200, height: 20)).width
            if x + 3 + labelWidth <= inset + layout.width {
                context.draw(resolved, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
            } else {
                context.draw(resolved, at: CGPoint(x: x - 3, y: 2), anchor: .topTrailing)
            }
        }
    }

    // MARK: Interaction

    private func dragChanged(_ value: DragGesture.Value, layout: TimelineLayout) {
        guard layout.total > 0 else { return }
        if drag == nil {
            // End any text editing (commits the title text) and give the
            // preview the keyboard back.
            PlayerLayerView.focusPreview(in: NSApp.keyWindow)
            let start = value.startLocation
            if start.y >= layout.titleTrackY, start.y < layout.segmentY - TimelineLayout.trackSpacing,
               let (title, part) = layout.titleHit(at: start),
               let range = TimelineMath.titleOutputRange(title, in: layout.project) {
                let additive = NSEvent.modifierFlags.contains(.command)
                drag = DragState(target: .title(
                    id: title.id, part: part, start: range.start, duration: title.duration,
                    additive: additive,
                    snapPoints: titleSnapPoints(excluding: title.id, in: layout.project)))
            } else if let point = layout.transitionHit(at: start) {
                drag = DragState(target: .transition(point))
            } else if let (clip, part) = layout.musicHit(at: start) {
                drag = DragState(target: .music(
                    clip: clip, part: part,
                    snapPoints: musicSnapPoints(excluding: clip.id, in: layout.project)))
            } else if let (id, duration, edge) = layout.stillEdgeHit(at: start),
                      let range = TimelineMath.segmentRange(id, in: layout.project) {
                drag = DragState(target: .stillEdge(
                    id: id, edge: edge, duration: duration,
                    snapPoints: snapPoints(excluding: id, in: layout.project),
                    edgeTime: edge == .leading ? range.start : range.end))
            } else if let (video, edge) = layout.segmentEdgeHit(at: start),
                      let range = TimelineMath.segmentRange(video.id, in: layout.project) {
                drag = DragState(target: .segmentEdge(
                    id: video.id, edge: edge, range: video.sourceRange,
                    edgeTime: edge == .leading ? range.start : range.end,
                    snapPoints: snapPoints(excluding: video.id, in: layout.project)))
            } else if let (clip, clipStart) = layout.clipHit(at: start),
                      NSEvent.modifierFlags.contains(.option) {
                drag = DragState(target: .shift(id: clip.id, start: clipStart, gapID: UUID()))
            } else if let (clip, clipStart) = layout.clipHit(at: start) {
                drag = DragState(target: .clip(
                    id: clip.id, start: clipStart, duration: clip.duration,
                    snapPoints: liftedSnapPoints(clip.id, in: layout.project)))
            } else {
                drag = DragState(target: .scrub)
            }
        }
        guard var state = drag else { return }
        lastDragValue = value
        defer { updateAutoScroll(at: value.location.x, layout: layout) }

        switch state.target {
        case .scrub:
            player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
        case .transition:
            return
        case let .title(id, part, start, duration, additive, snapPoints):
            guard !additive else { return }
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                drag = state
                if !store.selectedTitleIDs.contains(id) {
                    store.selectedTitleIDs = [id]
                    store.selectedSegmentID = nil
                }
                store.beginGesture(named: part == .body ? "Move Title" : "Change Title Duration")
            }
            var delta = Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            let candidates: [Tick] = switch part {
            case .body: [start + delta, start + duration + delta]
            case .leadingEdge: [start + delta]
            case .trailingEdge: [start + duration + delta]
            }
            let snap = TimelineMath.snap(candidates, to: snapPoints,
                                         tolerance: snapTolerance(layout))
            delta += snap?.shift ?? 0
            state.snappedTo = snap?.point
            drag = state
            let minimum = Ticks.perSecond / 10
            switch part {
            case .body:
                store.perform(.moveTitle(id: id, toOutputStart: max(start + delta, 0)))
            case .trailingEdge:
                store.perform(.setTitleDuration(id: id, duration: max(duration + delta, minimum)))
            case .leadingEdge:
                let end = start + duration
                let newStart = min(max(start + delta, 0), end - minimum)
                store.perform(.moveTitle(id: id, toOutputStart: newStart))
                store.perform(.setTitleDuration(id: id, duration: end - newStart))
            }
        case let .segmentEdge(id, edge, range, edgeTime, snapPoints):
            guard let clip = layout.project.segments.lazy.compactMap({ segment -> VideoSegment? in
                      if case .video(let video) = segment, video.id == id { video } else { nil }
                  }).first,
                  let source = layout.project.source(of: clip) else { return }
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
                store.beginGesture(named: ProjectCommand.trimSegment(id: id, sourceRange: range)
                    .actionName)
            }
            var delta = Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            let snap = TimelineMath.snap([edgeTime + delta], to: snapPoints,
                                         tolerance: snapTolerance(layout))
            delta += snap?.shift ?? 0
            state.snappedTo = snap?.point
            drag = state
            // The drag is output time; the trim is source time, at the clip's speed.
            let rate = clip.rate
            delta = Tick((Double(delta) * rate).rounded())
            let minimum = Tick((Double(ProjectCommand.minimumSegmentDuration(in: layout.project))
                                * rate).rounded(.up))
            let trimmed: TickRange
            switch edge {
            case .leading:
                let newStart = min(max(range.start + delta, 0), range.end - minimum)
                trimmed = TickRange(start: newStart, duration: range.end - newStart)
            case .trailing:
                let newEnd = min(max(range.end + delta, range.start + minimum), source.duration)
                trimmed = TickRange(start: range.start, duration: newEnd - range.start)
            }
            store.performInGesture(.trimSegment(id: id, sourceRange: trimmed))
        case let .stillEdge(id, edge, duration, snapPoints, edgeTime):
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
                store.beginGesture(named: isCard(id, in: layout.project)
                                   ? "Change Card Length" : "Change Freeze Length")
            }
            var delta = Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            let snap = TimelineMath.snap([edgeTime + delta], to: snapPoints,
                                         tolerance: snapTolerance(layout))
            delta += snap?.shift ?? 0
            state.snappedTo = snap?.point
            drag = state
            // Either end: dragging outwards lengthens it.
            let length = max(edge == .trailing ? duration + delta : duration - delta,
                             ProjectCommand.minimumSegmentDuration(in: layout.project))
            store.performInGesture(isCard(id, in: layout.project)
                                   ? .setCardDuration(id: id, duration: length)
                                   : .setStillDuration(id: id, duration: length))
        case let .music(clip, part, snapPoints):
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                store.selectedMusicID = clip.id
                store.beginGesture(named: "Change Music")
            }
            var delta = Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            let candidates: [Tick] = switch part {
            case .body: [clip.start + delta, clip.end + delta]
            case .leadingEdge: [clip.start + delta]
            case .trailingEdge: [clip.end + delta]
            }
            let snap = TimelineMath.snap(candidates, to: snapPoints,
                                         tolerance: snapTolerance(layout))
            delta += snap?.shift ?? 0
            state.snappedTo = snap?.point
            drag = state
            let others = layout.project.music
            let changed = switch part {
            case .body: MusicPlacement.moved(clip, to: clip.start + delta, among: others)
            case .leadingEdge:
                MusicPlacement.trimmedStart(clip, to: clip.start + delta, among: others)
            case .trailingEdge:
                MusicPlacement.trimmedEnd(clip, to: clip.end + delta, among: others)
            }
            store.performInGesture(.setMusic(changed))
        case let .clip(id, start, _, snapPoints):
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
                store.beginGesture(named: ProjectCommand.moveSegment(id: id, toOutputStart: start)
                    .actionName)
            }
            var newStart = start
                + Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            let snap = TimelineMath.snap([newStart], to: snapPoints,
                                         tolerance: snapTolerance(layout))
            newStart = max(newStart + (snap?.shift ?? 0), 0)
            state.snappedTo = snap?.point
            state.ghostStart = newStart
            drag = state
            store.performInGesture(.moveSegment(id: id, toOutputStart: newStart))
        case let .shift(id, start, gapID):
            let distance = value.translation.width
            if !state.isDragging {
                guard abs(distance) >= 3 else { return }
                state.isDragging = true
                frozenView = (layout.ticksPerPoint, layout.start)
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
                store.beginGesture(named: ProjectCommand.shiftSegments(
                    fromID: id, toOutputStart: start).actionName)
            }
            drag = state
            let newStart = start
                + Tick((Double(distance) * layout.ticksPerPoint + state.scrolled).rounded())
            store.performInGesture(.shiftSegments(fromID: id, toOutputStart: max(newStart, 0),
                                                  newGapID: gapID))
        }
    }

    // MARK: Auto-scroll

    /// Points inside each track edge where dragging starts to scroll.
    private static let autoScrollZone: CGFloat = 24

    /// Scroll speed in points per frame for a pointer `x`, negative to the
    /// left; 0 away from the edges or when nothing is being dragged.
    private func autoScrollSpeed(at x: CGFloat, layout: TimelineLayout) -> Double {
        guard let drag, drag.isDragging, frozenView != nil else { return 0 }
        if case .scrub = drag.target { return 0 }
        let left = TimelineLayout.leading + Self.autoScrollZone
        let right = TimelineLayout.leading + layout.width - Self.autoScrollZone
        let overshoot: CGFloat = x < left ? x - left : (x > right ? x - right : 0)
        guard overshoot != 0 else { return 0 }
        let speed = min(max(abs(Double(overshoot)) / 3, 2), 40)
        return overshoot < 0 ? -speed : speed
    }

    /// Starts or stops the frame loop that scrolls while the pointer is held
    /// at or past a track edge.
    private func updateAutoScroll(at x: CGFloat, layout: TimelineLayout) {
        guard autoScrollSpeed(at: x, layout: layout) != 0 else {
            autoScroll?.cancel()
            autoScroll = nil
            return
        }
        guard autoScroll == nil else { return }
        let fullWidth = layout.width + TimelineLayout.inset + TimelineLayout.leading
        autoScroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let value = lastDragValue, var state = drag,
                      var view = frozenView else { break }
                let layout = TimelineLayout(project: store.project, width: fullWidth, view: view)
                let speed = autoScrollSpeed(at: value.location.x, layout: layout)
                guard speed != 0 else { break }
                // Left stops at the timeline start; right may run past the
                // end, since the drag itself lengthens the timeline.
                let visible = Double(layout.width) * view.ticksPerPoint
                let latest = max(Double(layout.total) - visible / 2, view.start)
                let next = min(max(view.start + speed * view.ticksPerPoint, 0), latest)
                guard next != view.start else { continue }
                state.scrolled += next - view.start
                view.start = next
                frozenView = view
                drag = state
                dragChanged(value, layout: TimelineLayout(project: store.project,
                                                          width: fullWidth, view: view))
            }
            // A cancelled loop may already have been replaced.
            if !Task.isCancelled { autoScroll = nil }
        }
    }

    /// Clip edges, other music pieces' ends, the playhead and the timeline start.
    private func musicSnapPoints(excluding id: UUID, in project: Project) -> [Tick] {
        let pieces = project.music.filter { $0.id != id }.flatMap { [$0.start, $0.end] }
        return TimelineMath.clipEdges(project) + pieces
            + [0, Ticks.from(seconds: player.currentTime)]
    }

    /// Clip edges other than clip `id`'s, the playhead and the timeline start.
    /// Whether segment `id` is a title card.
    private func isCard(_ id: UUID, in project: Project) -> Bool {
        project.segments.contains { if case .card(let card) = $0 { card.id == id } else { false } }
    }

    private func snapPoints(excluding id: UUID, in project: Project) -> [Tick] {
        TimelineMath.clipEdges(project, excluding: id)
            + [0, Ticks.from(seconds: player.currentTime)]
    }

    /// Where a moved clip's start can snap: the clip edges of the timeline
    /// without it (where `moveSegment` measures), the playhead and 0.
    private func liftedSnapPoints(_ id: UUID, in project: Project) -> [Tick] {
        var lifted = project
        ProjectCommand.deleteSegment(id: id).apply(to: &lifted)
        return TimelineMath.clipEdges(lifted) + [0, Ticks.from(seconds: player.currentTime)]
    }

    /// Clip edges, the other titles' starts and ends, the playhead and the timeline start.
    private func titleSnapPoints(excluding id: UUID, in project: Project) -> [Tick] {
        let titles = project.titles.filter { $0.id != id }
            .compactMap { TimelineMath.titleOutputRange($0, in: project) }
            .flatMap { [$0.start, $0.end] }
        return TimelineMath.clipEdges(project) + titles
            + [0, Ticks.from(seconds: player.currentTime)]
    }

    private func snapTolerance(_ layout: TimelineLayout) -> Tick {
        Tick((Double(TimelineLayout.snapDistance) * layout.ticksPerPoint).rounded())
    }

    private func hoverChanged(_ phase: HoverPhase, layout: TimelineLayout) {
        if case .active(let point) = phase {
            hoverPoint = point
            let near = layout.isInSegmentTrack(point)
                ? layout.nearestPoint(toX: point.x, within: Self.menuReach) : nil
            if near != menuPoint { menuPoint = near }
        } else {
            hoverPoint = nil
        }
        updateCursor(layout: layout)
    }

    // MARK: Clip transitions

    /// Points from a cut within which right-clicking offers its transitions.
    private static let menuReach: CGFloat = 12

    /// The right-click menu at a cut: each kind that fits there, checked
    /// when it is the one there, and Remove.
    /// "+" drop-down: what can be added at the playhead, each off when it
    /// cannot be added there.
    private var addMenu: some View {
        let playhead = Ticks.from(seconds: player.currentTime)
        let canAddTitle = player.hasMedia && playhead < TimelineMath.outputDuration(store.project)
        let canFreeze = freezeFrame != nil
            && TimelineMath.sourceTime(playhead, in: store.project) != nil
        let isEnabled = canAddTitle || addMusic != nil || insertCard != nil || canFreeze
            || addVideo != nil
        return Menu {
            Button(action: addTitle) { Label("Title", systemImage: "textformat") }
                .disabled(!canAddTitle)
            Button(action: { insertCard?() }) { Label("Card", systemImage: "rectangle.fill") }
                .disabled(insertCard == nil)
            Button(action: { freezeFrame?() }) { Label("Freeze", systemImage: "camera") }
                .disabled(!canFreeze)
            Button(action: { addMusic?() }) { Label("Music…", systemImage: "music.note") }
                .disabled(addMusic == nil)
            Divider()
            Button(action: { addVideo?() }) { Label("Video at End…", systemImage: "film") }
                .disabled(addVideo == nil)
        } label: {
            shellMenuLabel(isEnabled: isEnabled) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            }
        }
        .shellMenu(isEnabled: isEnabled)
        .help("Add a title (T), card, freeze or music at the playhead, or a video at the end")
    }

    /// "Remove" drop-down: silences or filler words, each off when it cannot run.
    private var removeMenu: some View {
        let isEnabled = removeSilences != nil || removeFillers != nil
        return Menu {
            Button("Silences…") { removeSilences?() }
                .disabled(removeSilences == nil)
            Button("Filler Words…") { removeFillers?() }
                .disabled(removeFillers == nil)
        } label: {
            shellMenuLabel(isEnabled: isEnabled) { Text("Remove") }
        }
        .shellMenu(isEnabled: isEnabled)
        .help("Cut out silences or filler words")
    }

    /// A toolbar drop-down's label: `content` and a chevron, drawn like
    /// `BorderedShellButtonStyle`.
    private func shellMenuLabel(isEnabled: Bool,
                                @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 5) {
            content()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(isEnabled ? Theme.text : Theme.muted.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func transitionMenu(layout: TimelineLayout) -> some View {
        if let point = menuPoint, layout.transitionPoints.contains(where: { $0.point == point }) {
            let project = layout.project
            let current = point.transition(in: project)
            ForEach(ClipTransitionKind.allCases.filter {
                $0 != .crossfade || !point.isEdge(in: project)
            }, id: \.self) { kind in
                Toggle(kind.name(at: point, in: project), isOn: Binding(
                    get: { current?.kind == kind },
                    set: { _ in setTransition(kind, at: point) }))
            }
            if current != nil {
                Divider()
                Button("Remove Transition") {
                    store.perform(.setClipTransition(at: point, transition: nil))
                }
            }
        }
    }

    /// A palette drop: a crossfade at the video's start or end is a fade.
    private static func place(_ kind: ClipTransitionKind, at point: TransitionPoint,
                              store: ProjectStore) {
        let fits = kind != .crossfade || !point.isEdge(in: store.project)
        setTransition(fits ? kind : .dipToBlack, at: point, store: store)
    }

    private func setTransition(_ kind: ClipTransitionKind, at point: TransitionPoint) {
        Self.setTransition(kind, at: point, store: store)
    }

    /// Puts `kind` at `point`, keeping the length of any transition there,
    /// and selects it.
    private static func setTransition(_ kind: ClipTransitionKind, at point: TransitionPoint,
                                      store: ProjectStore) {
        var transition = point.transition(in: store.project) ?? ClipTransition(kind: kind)
        transition.kind = kind
        store.perform(.setClipTransition(at: point, transition: transition))
        if point.transition(in: store.project) != nil { store.selectedTransition = point }
    }

    /// The cursor for the pointer: resize over a music piece's edge or a
    /// clip edge and while trimming either; over the clip track, zoom with
    /// Command held, scroll arrows with Shift held while zoomed in. `nil` is
    /// the arrow.
    private func updateCursor(layout: TimelineLayout) {
        if let drag, case .segmentEdge = drag.target {
            setCursor(.resizeLeftRight)
            return
        }
        if let drag, case .stillEdge = drag.target {
            setCursor(.resizeLeftRight)
            return
        }
        if let drag, case .music(_, let part, _) = drag.target, part != .body {
            setCursor(.resizeLeftRight)
            return
        }
        if drag == nil, let point = hoverPoint, let (_, part) = layout.musicHit(at: point),
           part != .body {
            setCursor(.resizeLeftRight)
            return
        }
        guard drag == nil, let point = hoverPoint, layout.isInSegmentTrack(point),
              layout.transitionHit(at: point) == nil else {
            setCursor(nil)
            return
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            setCursor(.zoomIn)
        } else if flags.contains(.shift), !viewport.isFit {
            setCursor(Self.scrollCursor)
        } else if layout.segmentEdgeHit(at: point) != nil || layout.stillEdgeHit(at: point) != nil {
            setCursor(.resizeLeftRight)
        } else {
            setCursor(nil)
        }
    }

    private func setCursor(_ cursor: NSCursor?) {
        guard cursor !== shownCursor else { return }
        if shownCursor != nil { NSCursor.pop() }
        shownCursor = cursor
        cursor?.push()
    }

    /// Left and right arrows in a dark disc, for Shift-scrolling.
    private static let scrollCursor: NSCursor = {
        let size: CGFloat = 22
        let config = NSImage.SymbolConfiguration(pointSize: size - 4, weight: .semibold)
            .applying(.init(paletteColors: [.white, .black]))
        guard let symbol = NSImage(systemSymbolName: "arrow.left.and.right.circle.fill",
                                   accessibilityDescription: "Scroll")?
            .withSymbolConfiguration(config) else { return .resizeLeftRight }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // A white rim so the disc reads on the dark clip blocks.
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            let inner = rect.insetBy(dx: 2, dy: 2)
            symbol.draw(in: inner)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    private func dragEnded(_ value: DragGesture.Value, layout: TimelineLayout) {
        defer {
            if let frozenView, let drag, drag.scrolled != 0 {
                // Stay where auto-scroll left the view.
                viewport.ticksPerPoint = frozenView.ticksPerPoint
                viewport.start = frozenView.start
            }
            autoScroll?.cancel()
            autoScroll = nil
            lastDragValue = nil
            drag = nil
            frozenView = nil
            updateCursor(layout: layout)
        }
        guard let state = drag else { return }
        switch state.target {
        case .scrub:
            let tick = layout.tick(atX: value.location.x)
            player.seek(toSeconds: Ticks.seconds(tick))
            guard abs(value.translation.width) < 3 else { return }
            let y = value.startLocation.y
            if y >= layout.musicY {
                store.selectedMusicID = nil
            } else if y >= layout.segmentY {
                store.selectedSegmentID = TimelineMath.locate(tick, in: layout.project)?.segmentID
                store.selectedTitleIDs = []
            } else if y >= layout.titleTrackY {
                // Empty title track: clear the title selection.
                store.selectedTitleIDs = []
            }
        case let .segmentEdge(id, _, _, _, _):
            if state.isDragging {
                store.endGesture()
            } else {
                player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
            }
            hoverPoint = value.location
        case let .stillEdge(id, _, _, _, _):
            if state.isDragging {
                store.endGesture()
            } else {
                player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
            }
            store.selectedSegmentID = id
            store.selectedTitleIDs = []
        case let .transition(point):
            store.selectedTransition = point
        case let .music(clip, _, _):
            if state.isDragging {
                store.endGesture()
            } else {
                player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
                store.selectedMusicID = clip.id
            }
        case let .shift(id, _, _):
            if state.isDragging {
                store.endGesture()
            } else {
                player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
            }
        case let .clip(id, _, _, _):
            if state.isDragging {
                store.endGesture()
            } else {
                player.seek(toSeconds: Ticks.seconds(layout.tick(atX: value.location.x)))
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
                if NSApp.currentEvent?.clickCount == 2,
                   layout.project.segments.contains(where: {
                       if case .still(let still) = $0 { still.id == id } else { false }
                   }) {
                    editCamera(id)
                }
            }
        case let .title(id, _, _, _, additive, _):
            if state.isDragging {
                store.endGesture()
            } else if additive {
                if store.selectedTitleIDs.contains(id) {
                    store.selectedTitleIDs.remove(id)
                } else {
                    store.selectedTitleIDs.insert(id)
                }
                store.selectedSegmentID = nil
            } else {
                store.selectedTitleIDs = [id]
                store.selectedSegmentID = nil
            }
        }
    }
}

/// Zoom commands for the View menu, from the focused window's timeline.
struct TimelineZoomActions {
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomToFit: () -> Void
    var canZoomIn: Bool
    var canZoomOut: Bool
}

extension FocusedValues {
    /// Zoom of the focused document window's timeline.
    @Entry var timelineZoom: TimelineZoomActions?
}

/// Delivers trackpad pinches, horizontal scrolls and Command-scroll zooms
/// over the timeline.
///
/// SwiftUI has no scroll-wheel input for a plain view, so this watches the
/// window's events and takes those over its own frame. A horizontal scroll
/// is passed on when `onScroll` declines it.
private struct TimelineEventCatcher: NSViewRepresentable {
    /// Points to scroll, positive toward later times. Returns whether it was used.
    let onScroll: @MainActor (Double) -> Bool
    /// Magnification delta (zoom factor - 1) and the pointer's x in the view.
    let onMagnify: @MainActor (Double, CGFloat) -> Void
    /// A modifier key went down or up in this window.
    let onModifiersChanged: @MainActor () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onModifiersChanged = onModifiersChanged
    }

    final class CatcherView: NSView {
        var onScroll: (@MainActor (Double) -> Bool)?
        var onMagnify: (@MainActor (Double, CGFloat) -> Void)?
        var onModifiersChanged: (@MainActor () -> Void)?
        private var monitor: Any?

        /// Lines per mouse-wheel notch, in points.
        private static let lineHeight: Double = 10

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .flagsChanged]) {
                [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        /// Handles `event` if it is over this view. Returns whether it was used.
        private func consumes(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            if event.type == .flagsChanged {
                onModifiersChanged?()
                return false
            }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            switch event.type {
            case .magnify:
                onMagnify?(Double(event.magnification), point.x)
                return true
            case .scrollWheel where event.modifierFlags.contains(.command):
                // Toward "away" whatever the natural-scrolling setting.
                let away = Double(event.scrollingDeltaY)
                    * (event.isDirectionInvertedFromDevice ? -1 : 1)
                let factor = TimelineViewport.zoomFactor(
                    scrollDelta: away, isPrecise: event.hasPreciseScrollingDeltas)
                onMagnify?(factor - 1, point.x)
                return true
            case .scrollWheel:
                var dx = Double(event.scrollingDeltaX)
                guard abs(dx) > abs(Double(event.scrollingDeltaY)) else { return false }
                if !event.hasPreciseScrollingDeltas { dx *= Self.lineHeight }
                return onScroll?(-dx) == true
            default:
                return false
            }
        }
    }
}

private extension View {
    /// A toolbar drop-down with its label drawn by `shellMenuLabel`.
    func shellMenu(isEnabled: Bool) -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isEnabled)
    }
}
