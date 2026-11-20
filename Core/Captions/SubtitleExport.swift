import Foundation

/// SubRip (.srt) subtitles from the auto-captions on the timeline.
public enum SRT {
    /// One cue per auto-caption that has text and a non-empty output range,
    /// at output times, ordered by start (ties keep `project.titles` order).
    /// Cues may overlap. Empty when there are none.
    ///
    /// Line breaks are kept, normalised to `\n`; blank lines inside a title
    /// are dropped, since a blank line ends a cue in SRT. Cues are numbered
    /// from 1 and separated by a blank line.
    public static func make(_ project: Project) -> String {
        cues(project).enumerated().map { number, cue in
            "\(number + 1)\n\(timestamp(cue.range.start)) --> \(timestamp(cue.range.end))\n"
                + cue.text + "\n"
        }
        .joined(separator: "\n")
    }

    /// Whether `make` would write anything.
    public static func hasCues(_ project: Project) -> Bool {
        !cues(project).isEmpty
    }

    /// `HH:MM:SS,mmm`, rounded to the nearest millisecond.
    public static func timestamp(_ tick: Tick) -> String {
        // 1 tick = 5/3 ms; adding 1 before dividing by 3 rounds to nearest.
        let milliseconds = (max(tick, 0) * 5 + 1) / 3
        let seconds = milliseconds / 1000
        return String(format: "%02lld:%02lld:%02lld,%03lld", seconds / 3600, (seconds / 60) % 60,
                      seconds % 60, milliseconds % 1000)
    }

    private static func cues(_ project: Project) -> [(range: TickRange, text: String)] {
        project.titles.enumerated()
            .compactMap { index, title -> (Int, TickRange, String)? in
                guard title.origin == .autoCaption,
                      let range = TimelineMath.titleOutputRange(title, in: project),
                      range.duration > 0 else { return nil }
                let text = title.text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.allSatisfy(\.isWhitespace) }
                    .joined(separator: "\n")
                return text.isEmpty ? nil : (index, range, text)
            }
            .sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }
            .map { ($0.1, $0.2) }
    }
}
