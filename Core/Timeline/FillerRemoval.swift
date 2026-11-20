import Foundation

/// Finds filler sounds ("um", "uh" and similar) in a transcript and plans
/// the edits that cut them out of the timeline, closing up the time.
/// Real words that are sometimes fillers, such as "like", are never cut.
public enum FillerRemoval {
    /// Filler sounds, lowercased, without punctuation.
    public static let sounds: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mmm",
    ]

    /// Whether `text` is a filler sound, ignoring case and punctuation.
    public static func isFiller(_ text: String) -> Bool {
        sounds.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters
            .union(.whitespacesAndNewlines)))
    }

    /// Source ranges of the filler words in `words`, in time order.
    public static func fillers(in words: [TranscriptWord]) -> [TickRange] {
        words.filter { isFiller($0.text) && $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .map { TickRange(start: $0.start, duration: $0.end - $0.start) }
    }

    /// Output ranges to cut: each filler where a video segment plays it.
    public static func cuts(for words: [TranscriptWord], in project: Project) -> [TickRange] {
        cuts(for: [nil: words], in: project)
    }

    /// `cuts(for:in:)` with each video's words, keyed by `VideoSegment.sourceID`.
    public static func cuts(for words: [UUID?: [TranscriptWord]],
                            in project: Project) -> [TickRange] {
        SilenceRemoval.cuts(for: words.mapValues(fillers(in:)), in: project)
    }

    /// Commands that remove `cuts` (from `cuts(for:in:)`) and close up, in
    /// the order to perform them as one undo step. If the project has
    /// auto-captions, they are then rebuilt from `words` on the cut
    /// timeline, in the first caption's style, so cut fillers leave them.
    public static func commands(removing cuts: [TickRange], from project: Project,
                                words: [TranscriptWord],
                                makeID: () -> UUID = UUID.init) -> [ProjectCommand] {
        commands(removing: cuts, from: project, words: [nil: words], makeID: makeID)
    }

    /// `commands(removing:from:words:makeID:)` with each video's words,
    /// keyed by `VideoSegment.sourceID`.
    public static func commands(removing cuts: [TickRange], from project: Project,
                                words: [UUID?: [TranscriptWord]],
                                makeID: () -> UUID = UUID.init) -> [ProjectCommand] {
        var commands = SilenceRemoval.commands(removing: cuts, from: project, makeID: makeID)
        guard !commands.isEmpty,
              let caption = project.titles.first(where: { $0.origin == .autoCaption }),
              let style = project.styles.first(where: { $0.id == caption.styleID })
        else { return commands }
        var cut = project
        for command in commands { command.apply(to: &cut) }
        let titles = AutoCaptions.titles(for: words, in: cut, style: style, makeID: makeID)
        commands.append(.replaceAutoCaptions(titles: titles, style: style))
        return commands
    }
}
