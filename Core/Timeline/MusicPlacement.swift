import Foundation

/// Where music pieces may go: never before 0, never over another piece,
/// never past the ends of their song. Each function clamps instead of
/// refusing, for dragging.
public enum MusicPlacement {
    /// Shortest piece a trim leaves.
    public static let minimumDuration: Tick = Ticks.perSecond / 2

    /// `clip` moved to start at `start`, kept in the free space around where
    /// it was pressed.
    public static func moved(_ clip: MusicClip, to start: Tick,
                             among others: [MusicClip]) -> MusicClip {
        let (before, after) = room(around: clip, among: others)
        var moved = clip
        moved.start = min(max(start, before), max(after - clip.duration, before))
        return moved
    }

    /// `clip` with its start edge dragged to `start`: the song start moves
    /// with it, so the music under the end stays put.
    public static func trimmedStart(_ clip: MusicClip, to start: Tick,
                                    among others: [MusicClip]) -> MusicClip {
        let (before, _) = room(around: clip, among: others)
        let earliest = max(before, clip.start - clip.songRange.start)
        let latest = clip.end - minimumDuration
        let newStart = min(max(start, earliest), max(latest, earliest))
        var trimmed = clip
        trimmed.songRange = TickRange(start: clip.songRange.start + newStart - clip.start,
                                      duration: clip.end - newStart)
        trimmed.start = newStart
        return fitFades(trimmed)
    }

    /// `clip` with its end edge dragged to `end`.
    public static func trimmedEnd(_ clip: MusicClip, to end: Tick,
                                  among others: [MusicClip]) -> MusicClip {
        let (_, after) = room(around: clip, among: others)
        let latest = min(after, clip.start + clip.songDuration - clip.songRange.start)
        let newEnd = min(max(end, clip.start + minimumDuration), latest)
        var trimmed = clip
        trimmed.songRange.duration = newEnd - clip.start
        return fitFades(trimmed)
    }

    /// A new piece of a song of `songDuration` at `playhead`: after the
    /// piece the playhead is in, if any, running to the next piece or the
    /// end of the video, or the end of the song. `nil` when less than
    /// `minimumDuration` is free there.
    public static func newPiece(id: UUID, fileName: String, name: String, songDuration: Tick,
                                at playhead: Tick, among others: [MusicClip],
                                videoDuration: Tick) -> MusicClip? {
        var start = max(playhead, 0)
        if let covering = others.first(where: { $0.start <= start && start < $0.end }) {
            start = covering.end
        }
        let next = others.filter { $0.start >= start }.map(\.start).min() ?? .max
        let length = min(songDuration, min(next, videoDuration) - start)
        guard length >= minimumDuration else { return nil }
        return fitFades(MusicClip(id: id, fileName: fileName, name: name,
                                  songDuration: songDuration, start: start,
                                  songRange: TickRange(start: 0, duration: length)))
    }

    /// Free output time around `clip`: the end of the piece before it and
    /// the start of the piece after it.
    private static func room(around clip: MusicClip,
                             among others: [MusicClip]) -> (before: Tick, after: Tick) {
        let rest = others.filter { $0.id != clip.id }
        let before = rest.filter { $0.end <= clip.start + clip.duration / 2 }
            .map(\.end).max() ?? 0
        let after = rest.filter { $0.start >= clip.start + clip.duration / 2 }
            .map(\.start).min() ?? .max
        return (before, after)
    }

    /// Shortens the fades so both fit inside the piece.
    public static func fitFades(_ clip: MusicClip) -> MusicClip {
        var fitted = clip
        fitted.fadeIn = min(clip.fadeIn, clip.duration)
        fitted.fadeOut = min(clip.fadeOut, clip.duration - fitted.fadeIn)
        return fitted
    }
}
