import Foundation

/// How the picture changes at a cut, the video's start or its end.
///
/// Stored on the segment after the cut (`transitionIn`), or on the last
/// segment for the video's end (`transitionOut`). It never changes the
/// video's length: it plays across the cut, half before and half after.
public struct ClipTransition: Codable, Sendable, Equatable {
    public var kind: ClipTransitionKind
    /// Whole length across the cut. At the video's start or end it is all
    /// on one side. Shortened when it plays to draw if a neighbouring
    /// segment is too short (`ClipTransitionPlan`).
    public var duration: Tick

    public init(kind: ClipTransitionKind, duration: Tick = ClipTransition.defaultDuration) {
        self.kind = kind
        self.duration = duration
    }

    /// 1 s.
    public static let defaultDuration: Tick = Ticks.perSecond
    /// 0.1 s.
    public static let minimumDuration: Tick = Ticks.perSecond / 10
    /// 5 s.
    public static let maximumDuration: Tick = 5 * Ticks.perSecond
}

public enum ClipTransitionKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// To black, then from black. At the video's start or end, a fade.
    case dipToBlack
    /// To white, then from white.
    case dipToWhite
    /// The two clips blend. Each borrows frames from past its cut in the
    /// source; where the source ends, its edge frame holds. Cuts only.
    case crossfade

    /// For menus and the inspector.
    public var name: String {
        switch self {
        case .dipToBlack: "Dip to Black"
        case .dipToWhite: "Dip to White"
        case .crossfade: "Crossfade"
        }
    }

    /// For the video's start or end, where there is nothing to blend with.
    public func name(at point: TransitionPoint, in project: Project) -> String {
        guard self != .crossfade else { return name }
        let colour = self == .dipToBlack ? "Black" : "White"
        switch point {
        case .end: return "Fade to \(colour)"
        case .before(let id) where project.segments.first?.id == id:
            return "Fade from \(colour)"
        case .before: return name
        }
    }
}

/// Where a transition sits.
public enum TransitionPoint: Hashable, Sendable {
    /// The cut before segment `id`; the video's start for the first segment.
    case before(UUID)
    /// The video's end.
    case end

    /// The point at output time `time` exactly: the start, a cut, or the end.
    public static func at(_ time: Tick, in project: Project) -> TransitionPoint? {
        var cursor: Tick = 0
        for segment in project.segments {
            if cursor == time { return .before(segment.id) }
            cursor += segment.duration
        }
        return cursor == time && !project.segments.isEmpty ? .end : nil
    }

    /// Output time of the point; `nil` if its segment is missing.
    public func time(in project: Project) -> Tick? {
        switch self {
        case .before(let id): TimelineMath.segmentStart(id, in: project)
        case .end: project.segments.isEmpty ? nil : TimelineMath.outputDuration(project)
        }
    }

    /// The video's start or end, where only fades apply.
    public func isEdge(in project: Project) -> Bool {
        switch self {
        case .end: true
        case .before(let id): project.segments.first?.id == id
        }
    }

    /// The transition there, if any.
    public func transition(in project: Project) -> ClipTransition? {
        switch self {
        case .before(let id): project.segments.first { $0.id == id }?.transitionIn
        case .end: project.segments.last?.transitionOut
        }
    }
}

extension Segment {
    /// The transition at the cut before this segment (the video's start for
    /// the first).
    public var transitionIn: ClipTransition? {
        get {
            switch self {
            case .video(let segment): segment.transitionIn
            case .still(let segment): segment.transitionIn
            case .card(let segment): segment.transitionIn
            case .gap(let segment): segment.transitionIn
            }
        }
        set {
            switch self {
            case .video(var segment): segment.transitionIn = newValue; self = .video(segment)
            case .still(var segment): segment.transitionIn = newValue; self = .still(segment)
            case .card(var segment): segment.transitionIn = newValue; self = .card(segment)
            case .gap(var segment): segment.transitionIn = newValue; self = .gap(segment)
            }
        }
    }

    /// The transition at the video's end; only the last segment keeps one.
    /// Always `nil` for a gap, which is never last.
    public var transitionOut: ClipTransition? {
        get {
            switch self {
            case .video(let segment): segment.transitionOut
            case .still(let segment): segment.transitionOut
            case .card(let segment): segment.transitionOut
            case .gap: nil
            }
        }
        set {
            switch self {
            case .video(var segment): segment.transitionOut = newValue; self = .video(segment)
            case .still(var segment): segment.transitionOut = newValue; self = .still(segment)
            case .card(var segment): segment.transitionOut = newValue; self = .card(segment)
            case .gap: break
            }
        }
    }
}
