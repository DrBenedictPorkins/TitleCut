import Foundation

/// Pure mapping between output time and segments (§4.2).
///
/// Output time is the position on the edited timeline. Segment ranges are
/// half-open: a time exactly on a boundary belongs to the later segment. The
/// one exception is the very end of the timeline, which locates to the last
/// segment at offset == its duration.
public enum TimelineMath {
    /// Where an output time falls.
    public struct Location: Equatable, Sendable {
        public var segmentID: UUID
        public var index: Int
        public var offset: Tick

        public init(segmentID: UUID, index: Int, offset: Tick) {
            self.segmentID = segmentID
            self.index = index
            self.offset = offset
        }
    }

    /// Sum of all segment durations.
    public static func outputDuration(_ project: Project) -> Tick {
        project.segments.reduce(0) { $0 + $1.duration }
    }

    /// Output start time of segment `id`, or `nil` if it is not in the project.
    public static func segmentStart(_ id: UUID, in project: Project) -> Tick? {
        var cursor: Tick = 0
        for segment in project.segments {
            if segment.id == id { return cursor }
            cursor += segment.duration
        }
        return nil
    }

    /// Output range of segment `id`.
    public static func segmentRange(_ id: UUID, in project: Project) -> TickRange? {
        guard let start = segmentStart(id, in: project),
              let segment = project.segments.first(where: { $0.id == id }) else { return nil }
        return TickRange(start: start, duration: segment.duration)
    }

    /// The segment containing `outputTime`, or `nil` outside `0...outputDuration`.
    public static func locate(_ outputTime: Tick, in project: Project) -> Location? {
        guard outputTime >= 0 else { return nil }
        var cursor: Tick = 0
        for (index, segment) in project.segments.enumerated() {
            if outputTime < cursor + segment.duration {
                return Location(segmentID: segment.id, index: index, offset: outputTime - cursor)
            }
            cursor += segment.duration
        }
        if outputTime == cursor, let last = project.segments.last {
            return Location(segmentID: last.id, index: project.segments.count - 1,
                            offset: last.duration)
        }
        return nil
    }

    /// Source video time at `outputTime`, in the video the clip there plays
    /// (`sourcePoint`); `nil` inside a still or outside the timeline.
    public static func sourceTime(_ outputTime: Tick, in project: Project) -> Tick? {
        sourcePoint(outputTime, in: project)?.time
    }

    /// The clip at `outputTime`, and its source time there; `nil` inside a
    /// still or outside the timeline. `clip.sourceID` names its video.
    public static func sourcePoint(_ outputTime: Tick,
                                   in project: Project) -> (clip: VideoSegment, time: Tick)? {
        guard let location = locate(outputTime, in: project),
              case .video(let video) = project.segments[location.index] else { return nil }
        return (video, video.sourceRange.start + video.sourceOffset(atOutput: location.offset))
    }

    /// Output range of a title. Titles may run past their segment into later
    /// ones; they are clamped only to the total output duration.
    /// `nil` if the anchor segment is missing.
    public static func titleOutputRange(_ title: Title, in project: Project) -> TickRange? {
        guard let segmentStart = segmentStart(title.anchor.segmentID, in: project) else {
            return nil
        }
        let total = outputDuration(project)
        let start = min(max(segmentStart + title.anchor.offset, 0), total)
        let end = min(start + max(title.duration, 0), total)
        return TickRange(start: start, duration: end - start)
    }

    /// Title track lane for each title (§7.3). Lane 0 is the main lane;
    /// overlapping titles stack into higher lanes.
    ///
    /// Titles are placed in `project.titles` order, each in the lowest lane
    /// free of overlap with titles placed before it. Ranges are half-open, so
    /// titles that only touch share a lane. Placing in array order rather than
    /// start order keeps lanes stable while a title is dragged: titles before
    /// it never change lane. Titles whose segment is missing are omitted.
    public static func titleLanes(_ project: Project) -> [UUID: Int] {
        var lanes: [[TickRange]] = []
        var result: [UUID: Int] = [:]
        for title in project.titles {
            guard let range = titleOutputRange(title, in: project) else { continue }
            let lane = lanes.firstIndex { placed in
                !placed.contains { $0.start < range.end && range.start < $0.end }
            } ?? lanes.count
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(range)
            result[title.id] = lane
        }
        return result
    }

    /// The smallest shift that puts one of `candidates` on one of `points`,
    /// if any is within `tolerance`. Ties go to the earlier candidate, then
    /// the earlier point.
    /// - Returns: The shift to add, and the point snapped to.
    public static func snap(_ candidates: [Tick], to points: [Tick],
                            tolerance: Tick) -> (shift: Tick, point: Tick)? {
        var best: (shift: Tick, point: Tick)?
        for candidate in candidates {
            for point in points {
                let shift = point - candidate
                guard abs(shift) <= tolerance else { continue }
                if best.map({ abs(shift) < abs($0.shift) }) ?? true { best = (shift, point) }
            }
        }
        return best
    }

    /// Output times of every clip edge (video or still), excluding clip `id`'s own.
    public static func clipEdges(_ project: Project, excluding id: UUID? = nil) -> [Tick] {
        var edges: [Tick] = []
        var cursor: Tick = 0
        for segment in project.segments {
            if !segment.isGap, segment.id != id {
                edges.append(cursor)
                edges.append(cursor + segment.duration)
            }
            cursor += segment.duration
        }
        return edges
    }

    /// Splits `segment` at `offset` (from its start). The first half keeps the
    /// original ID and the transition before it; the second half gets `newID`
    /// and the transition at the end. `nil` for a gap, and unless
    /// `0 < offset < duration`.
    public static func split(_ segment: Segment, at offset: Tick,
                             newID: UUID) -> (Segment, Segment)? {
        guard offset > 0, offset < segment.duration else { return nil }
        switch segment {
        case .video(let video):
            // At another speed the halves' lengths are rounded to whole ticks,
            // so the first may differ from `offset` by a tick.
            let range = video.sourceRange
            let at = video.sourceOffset(atOutput: offset)
            guard at > 0, at < range.duration else { return nil }
            var first = video
            first.sourceRange = TickRange(start: range.start, duration: at)
            first.transitionOut = nil
            var second = video
            second.id = newID
            second.sourceRange = TickRange(start: range.start + at, duration: range.duration - at)
            second.transitionIn = nil
            return (.video(first), .video(second))
        case .still(let still):
            var first = still
            first.duration = offset
            first.transitionOut = nil
            first.zoom = still.zoom.filter { $0.time < offset }
            var second = still
            second.id = newID
            second.transitionIn = nil
            second.duration = still.duration - offset
            second.zoom = still.zoom
                .filter { $0.time >= offset }
                .map { keyframe in
                    var shifted = keyframe
                    shifted.time -= offset
                    return shifted
                }
            return (.still(first), .still(second))
        case .card(let card):
            var first = card
            first.duration = offset
            first.transitionOut = nil
            var second = card
            second.id = newID
            second.transitionIn = nil
            second.duration = card.duration - offset
            return (.card(first), .card(second))
        case .gap:
            return nil
        }
    }
}
