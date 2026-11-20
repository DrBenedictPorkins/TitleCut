import Foundation

/// Turns a transcript into caption titles on the timeline. Pure and
/// deterministic: the same words, project and IDs give the same titles.
public enum AutoCaptions {
    /// How words are grouped into caption lines.
    public struct Rules: Sendable, Equatable {
        public var maxWords = 7
        public var maxCharacters = 42
        /// Longest line, first word start to last word end.
        public var maxDuration: Tick = 3 * Ticks.perSecond
        /// A silence longer than this starts a new line.
        public var pauseGap: Tick = Ticks.perSecond / 2
        /// Short lines are held on screen this long, if the next line and
        /// the segment end allow.
        public var minDuration: Tick = Ticks.perSecond * 4 / 5

        public init() {}
    }

    /// One caption line in source time.
    public struct Line: Sendable, Equatable {
        public var text: String
        public var start: Tick
        public var end: Tick
        /// The words joined into `text`, trimmed, in source time.
        public var words: [TranscriptWord]

        public init(text: String, start: Tick, end: Tick, words: [TranscriptWord] = []) {
            self.text = text
            self.start = start
            self.end = end
            self.words = words
        }
    }

    /// 0.1 s fade in.
    public static let transitionIn = Transition(kind: .fade, duration: Ticks.perSecond / 10,
                                                easing: .easeOut)
    /// 0.1 s fade out.
    public static let transitionOut = Transition(kind: .fade, duration: Ticks.perSecond / 10,
                                                 easing: .easeIn)

    /// Every title Auto-Captions made, for Select All Captions.
    public static func titleIDs(in project: Project) -> Set<UUID> {
        Set(project.titles.filter { $0.origin == .autoCaption }.map(\.id))
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]

    /// Groups `words` (in time order) into lines. A line ends after a word
    /// that ends a sentence, and before a word that would follow a pause or
    /// take the line past any limit in `rules`.
    public static func lines(_ words: [TranscriptWord], rules: Rules = Rules()) -> [Line] {
        var lines: [Line] = []
        var current: [TranscriptWord] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Line(text: current.map(\.text).joined(separator: " "),
                              start: first.start, end: max(last.end, first.start),
                              words: current))
            current = []
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let word = TranscriptWord(text: text, start: word.start, end: word.end)
            if let first = current.first, let last = current.last {
                let characters = current.map(\.text.count).reduce(current.count, +) + text.count
                if current.count >= rules.maxWords
                    || characters > rules.maxCharacters
                    || word.end - first.start > rules.maxDuration
                    || word.start - last.end > rules.pauseGap {
                    close()
                }
            }
            current.append(word)
            if let character = text.last, sentenceEnds.contains(character) { close() }
        }
        close()
        return lines
    }

    /// Caption titles for `words` (source time) on `project`'s timeline.
    ///
    /// Each video segment takes the words that start inside its source range;
    /// words in trimmed-out or deleted footage are dropped. Lines are made per
    /// segment, anchored to it and clipped to its end, so a caption never
    /// shows over footage it was not spoken in.
    ///
    /// - Parameter makeID: Called once per title, in output order.
    public static func titles(for words: [TranscriptWord], in project: Project,
                              style: TitleStyle, rules: Rules = Rules(),
                              makeID: () -> UUID) -> [Title] {
        titles(for: [nil: words], in: project, style: style, rules: rules, makeID: makeID)
    }

    /// `titles(for:in:style:rules:makeID:)` for a timeline of several
    /// videos: each clip takes the words of its video, keyed by
    /// `VideoSegment.sourceID`. Clips of a video with no words get none.
    public static func titles(for words: [UUID?: [TranscriptWord]], in project: Project,
                              style: TitleStyle, rules: Rules = Rules(),
                              makeID: () -> UUID) -> [Title] {
        let sorted = words.mapValues {
            $0.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }
        var titles: [Title] = []
        for segment in project.segments {
            guard case .video(let video) = segment else { continue }
            let range = video.sourceRange
            let inside = (sorted[video.sourceID] ?? []).filter { range.contains($0.start) }
            let segmentLines = lines(inside, rules: rules)
            for (index, line) in segmentLines.enumerated() {
                let nextStart = index + 1 < segmentLines.count
                    ? segmentLines[index + 1].start : range.end
                // The minimum hold is output time; the rest is source time,
                // mapped to output at the clip's speed.
                let lineStart = video.outputOffset(ofSource: line.start)
                let held = max(video.outputOffset(ofSource: line.end),
                               min(lineStart + rules.minDuration,
                                   video.outputOffset(ofSource: nextStart)))
                let end = min(held, video.outputDuration)
                guard end > lineStart else { continue }
                let duration = end - lineStart
                // Times from the title's start, clamped into its duration. Every
                // word is kept so the words still match the text; one cut off
                // by the segment end starts at the end and is never highlighted.
                let timed = line.words.map { word in
                    let start = min(max(video.outputOffset(ofSource: word.start) - lineStart, 0),
                                    duration)
                    return TimedWord(text: word.text, start: start,
                                     end: min(max(video.outputOffset(ofSource: word.end)
                                                      - lineStart, start), duration))
                }
                titles.append(Title(
                    id: makeID(), text: line.text,
                    anchor: TitleAnchor(segmentID: video.id, offset: lineStart),
                    duration: duration, styleID: style.id,
                    transitionIn: transitionIn, transitionOut: transitionOut,
                    origin: .autoCaption, words: timed))
            }
        }
        return titles
    }
}
