import Foundation

/// Where each clip transition plays on the output timeline (§6.1).
///
/// A transition at a cut plays half before it and half after. Each side is
/// cut to half the segment on that side, so the transitions at a segment's
/// two ends never meet. At the video's start it plays wholly after, and at
/// its end wholly before, each cut to half the segment there.
public enum ClipTransitionPlan {
    public struct Window: Equatable, Sendable {
        /// The cut: output start of segment `index`, or the output end when
        /// `index == segments.count`.
        public var time: Tick
        /// The segment after the cut; `segments.count` for the end.
        public var index: Int
        public var kind: ClipTransitionKind
        /// Ticks played before and after `time`.
        public var before: Tick
        public var after: Tick

        /// At the video's start or end: no segment on one side.
        public var isEdge: Bool
    }

    /// Every transition that plays, in time order. Transitions with no
    /// room to play are left out.
    public static func windows(_ project: Project) -> [Window] {
        let segments = project.segments
        var windows: [Window] = []
        var cursor: Tick = 0
        for (index, segment) in segments.enumerated() {
            if let transition = segment.transitionIn {
                let window: Window
                if index == 0 {
                    window = Window(time: cursor, index: index, kind: transition.kind, before: 0,
                                    after: min(transition.duration, segment.duration / 2),
                                    isEdge: true)
                } else {
                    let half = transition.duration / 2
                    window = Window(time: cursor, index: index, kind: transition.kind,
                                    before: min(half, segments[index - 1].duration / 2),
                                    after: min(transition.duration - half, segment.duration / 2),
                                    isEdge: false)
                }
                if window.before + window.after > 0 { windows.append(window) }
            }
            cursor += segment.duration
        }
        if let last = segments.last, let transition = last.transitionOut {
            let window = Window(time: cursor, index: segments.count, kind: transition.kind,
                                before: min(transition.duration, last.duration / 2), after: 0,
                                isEdge: true)
            if window.before > 0 { windows.append(window) }
        }
        return windows
    }
}
