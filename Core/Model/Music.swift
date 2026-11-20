import Foundation

/// A piece of a song on the music strip, placed in output time (finished-
/// video time). Cutting or moving video never moves it. Pieces never overlap.
///
/// The song file is copied into the package at `music/<fileName>`.
public struct MusicClip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// `music/<id>.<ext>` inside the package.
    public var fileName: String
    /// The song's name as added, for display.
    public var name: String
    /// Length of the whole song.
    public var songDuration: Tick
    /// Output time the piece starts at.
    public var start: Tick
    /// The part of the song that plays.
    public var songRange: TickRange
    /// 0...1.
    public var volume: Double
    public var fadeIn: Tick
    public var fadeOut: Tick

    public init(id: UUID, fileName: String, name: String, songDuration: Tick, start: Tick,
                songRange: TickRange, volume: Double = 0.6, fadeIn: Tick = 300,
                fadeOut: Tick = 600) {
        self.id = id
        self.fileName = fileName
        self.name = name
        self.songDuration = songDuration
        self.start = start
        self.songRange = songRange
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// Private pasteboard type for a copied piece, as JSON.
    public static let pasteboardType = "com.byteclub.titlecut.music"

    public var duration: Tick { songRange.duration }
    public var end: Tick { start + duration }
    public var outputRange: TickRange { TickRange(start: start, duration: duration) }

    /// Whether the piece is well formed: inside its song, starting at or
    /// after 0, with fades that fit.
    var isValid: Bool {
        start >= 0 && songRange.start >= 0 && songRange.duration > 0
            && songRange.end <= songDuration && (0...1).contains(volume)
            && fadeIn >= 0 && fadeOut >= 0 && fadeIn + fadeOut <= songRange.duration
    }
}
