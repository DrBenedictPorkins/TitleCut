import Foundation

/// Finds quiet stretches in the source audio and plans the edits that cut
/// them out of the timeline, closing up the time.
public enum SilenceRemoval {
    public struct Settings: Sendable, Equatable {
        /// Audio quieter than this, in dB below the file's loudest part
        /// (`Waveform` reference), counts as silence. Positive.
        public var thresholdDecibels: Double
        /// Shorter pauses are kept.
        public var minimumSeconds: Double
        /// Kept at each end of a pause so words are not clipped.
        public var paddingSeconds: Double
        /// Shortest piece of video left between two cuts. Where cuts sit
        /// closer than this, only the longest of them is made.
        public var minimumKeptSeconds: Double

        public init(thresholdDecibels: Double = 30, minimumSeconds: Double = 0.6,
                    paddingSeconds: Double = 0.15, minimumKeptSeconds: Double = 1.5) {
            self.thresholdDecibels = thresholdDecibels
            self.minimumSeconds = minimumSeconds
            self.paddingSeconds = paddingSeconds
            self.minimumKeptSeconds = minimumKeptSeconds
        }
    }

    /// Silent stretches of the source, in source ticks, padding removed.
    /// - Parameter loudest: The level the threshold is measured down from:
    ///   1 for the whole file's loudest part, lower for a quieter selection.
    public static func silences(in waveform: Waveform, settings: Settings,
                                loudest: Float = 1) -> [TickRange] {
        let level = loudest - Float(settings.thresholdDecibels / Double(Waveform.floorDecibels))
        let binTicks = Double(Ticks.perSecond) / Waveform.binsPerSecond
        var ranges: [TickRange] = []
        var runStart: Int?
        for index in 0...waveform.peaks.count {
            let quiet = index < waveform.peaks.count && waveform.peaks[index] < level
            if quiet {
                if runStart == nil { runStart = index }
            } else if let first = runStart {
                runStart = nil
                let seconds = Double(index - first) / Waveform.binsPerSecond
                guard seconds >= settings.minimumSeconds else { continue }
                let padding = Tick((settings.paddingSeconds * Double(Ticks.perSecond)).rounded())
                // A pause at the very start or end of the audio needs no padding there.
                let start = Tick((Double(first) * binTicks).rounded())
                    + (first == 0 ? 0 : padding)
                let end = Tick((Double(index) * binTicks).rounded())
                    - (index == waveform.peaks.count ? 0 : padding)
                if end > start { ranges.append(TickRange(start: start, duration: end - start)) }
            }
        }
        return spaced(ranges, minimumKept: Tick((settings.minimumKeptSeconds * Double(Ticks.perSecond)).rounded()))
    }

    /// `ranges` thinned so at least `minimumKept` ticks lie between any two:
    /// longest first, each kept only if it is far enough from those kept.
    static func spaced(_ ranges: [TickRange], minimumKept: Tick) -> [TickRange] {
        guard minimumKept > 0 else { return ranges }
        var kept: [TickRange] = []
        for range in ranges.sorted(by: { $0.duration > $1.duration }) {
            let clear = kept.allSatisfy { other in
                range.end + minimumKept <= other.start || other.end + minimumKept <= range.start
            }
            if clear { kept.append(range) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// Output ranges to cut: each silence where a video segment plays it,
    /// one segment at a time, in output order. A piece of a segment left
    /// shorter than `minimumSegmentDuration` is cut with the silence.
    public static func cuts(for silences: [TickRange], in project: Project) -> [TickRange] {
        cuts(for: [nil: silences], in: project)
    }

    /// `cuts(for:in:)` for a timeline of several videos: each clip takes the
    /// silences of its video, keyed by `VideoSegment.sourceID`.
    public static func cuts(for silences: [UUID?: [TickRange]],
                            in project: Project) -> [TickRange] {
        let minimum = ProjectCommand.minimumSegmentDuration(in: project)
        var cuts: [TickRange] = []
        var cursor: Tick = 0
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard case .video(let video) = segment else { continue }
            let range = video.sourceRange
            for silence in silences[video.sourceID] ?? [] {
                // In output time, at the clip's speed.
                let length = video.outputDuration
                var start = video.outputOffset(ofSource: max(silence.start, range.start))
                var end = video.outputOffset(ofSource: min(silence.end, range.end))
                guard end - start >= minimum else { continue }
                if start < minimum { start = 0 }
                if length - end < minimum { end = length }
                cuts.append(TickRange(start: cursor + start, duration: end - start))
            }
        }
        return cuts
    }

    /// Each video's loudest level where it plays inside `range` (uncut
    /// output time), keyed by `VideoSegment.sourceID`.
    public static func loudest(in range: TickRange, of project: Project,
                               waveforms: [UUID?: Waveform]) -> [UUID?: Float] {
        var result: [UUID?: Float] = [:]
        var cursor: Tick = 0
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard case .video(let video) = segment, let waveform = waveforms[video.sourceID]
            else { continue }
            let start = max(range.start, cursor), end = min(range.end, cursor + segment.duration)
            guard end > start else { continue }
            let from = video.sourceRange.start + video.sourceOffset(atOutput: start - cursor)
            let to = video.sourceRange.start + video.sourceOffset(atOutput: end - cursor)
            let peak = waveform.peak(fromSeconds: Ticks.seconds(from), toSeconds: Ticks.seconds(to))
            result[video.sourceID] = max(result[video.sourceID] ?? 0, peak)
        }
        return result
    }

    /// `cuts` trimmed to `range` (uncut output time); those outside it dropped.
    public static func cuts(_ cuts: [TickRange], within range: TickRange?) -> [TickRange] {
        guard let range else { return cuts }
        return cuts.compactMap { cut in
            let start = max(cut.start, range.start), end = min(cut.end, range.end)
            return end > start ? TickRange(start: start, duration: end - start) : nil
        }
    }

    /// `project` with `cuts` removed, for previewing before committing.
    public static func project(_ project: Project, removing cuts: [TickRange]) -> Project {
        var result = project
        for command in commands(removing: cuts, from: project) { _ = command.apply(to: &result) }
        return result
    }

    /// Where output time `time` of the uncut timeline plays after `cuts`.
    /// Time inside a cut lands where the cut was.
    public static func keptTime(_ time: Tick, cuts: [TickRange]) -> Tick {
        var kept = time
        for cut in cuts {
            if time >= cut.end { kept -= cut.duration } else if time > cut.start { kept -= time - cut.start }
        }
        return kept
    }

    /// The uncut output time that plays at `time` after `cuts`.
    public static func originalTime(_ time: Tick, cuts: [TickRange]) -> Tick {
        var original = time
        for cut in cuts.sorted(by: { $0.start < $1.start }) where cut.start <= original {
            original += cut.duration
        }
        return original
    }

    /// Commands that remove `cuts` (from `cuts(for:in:)`) and close up,
    /// in the order to perform them as one undo step.
    ///
    /// Each cut becomes its own segment by splitting at its ends, and is
    /// deleted. Titles that start inside it move to where it was, so none
    /// is lost. Cutting every segment away is refused: the last one is kept.
    public static func commands(removing cuts: [TickRange], from project: Project,
                                makeID: () -> UUID = UUID.init) -> [ProjectCommand] {
        var project = project
        var commands: [ProjectCommand] = []
        func run(_ command: ProjectCommand) {
            if command.apply(to: &project) { commands.append(command) }
        }
        // Last first, so earlier output times stay where they were.
        for cut in cuts.sorted(by: { $0.start > $1.start }) {
            guard let location = TimelineMath.locate(cut.start, in: project),
                  location.offset < project.segments[location.index].duration else { continue }
            let segmentStart = cut.start - location.offset
            let segmentEnd = segmentStart + project.segments[location.index].duration
            guard cut.end <= segmentEnd else { continue }
            if cut.end < segmentEnd { run(.splitSegment(atOutputTime: cut.end, newSegmentID: makeID())) }
            if cut.start > segmentStart {
                run(.splitSegment(atOutputTime: cut.start, newSegmentID: makeID()))
            }
            guard let middle = TimelineMath.locate(cut.start, in: project)?.segmentID,
                  project.segments.count > 1 else { continue }
            let total = TimelineMath.outputDuration(project)
            // After the cut, the join is at `cut.start`; before it, that is
            // `cut.end`, or the last tick before the cut when nothing follows.
            let landing = cut.end < total ? cut.end : max(cut.start - 1, 0)
            for title in project.titles where title.anchor.segmentID == middle {
                run(.moveTitle(id: title.id, toOutputStart: landing))
            }
            run(.deleteSegment(id: middle))
        }
        return commands
    }
}
