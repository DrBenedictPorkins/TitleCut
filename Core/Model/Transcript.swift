import AVFoundation

/// One video's speech with word timings, saved in the package in
/// `transcripts.json` so a video is transcribed once.
public struct Transcript: Codable, Sendable, Equatable {
    /// Highest format this build reads and the format it writes.
    public static let currentFormatVersion = 1

    public var formatVersion: Int = Transcript.currentFormatVersion
    /// BCP 47 identifier of the language transcribed, e.g. "en-US".
    public var locale: String
    /// The source the words came from; a different source invalidates them.
    public var source: SourceFingerprint
    /// In time order.
    public var words: [TranscriptWord]

    public init(locale: String, source: SourceFingerprint, words: [TranscriptWord]) {
        self.locale = locale
        self.source = source
        self.words = words
    }

    /// Whether this transcript was made from `source` in `locale`.
    public func matches(_ source: SourceFingerprint, locale: String) -> Bool {
        self.source == source && self.locale == locale
    }
}

extension [Transcript] {
    /// `transcripts` with `transcript` in place of any earlier one of the
    /// same video.
    public func replacing(with transcript: Transcript) -> [Transcript] {
        filter { $0.source != transcript.source } + [transcript]
    }
}

/// One spoken word, with any punctuation attached, in source time.
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Tick
    public var end: Tick

    public init(text: String, start: Tick, end: Tick) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Identifies a source file by content, not location, so a moved or
/// relinked copy of the same file still matches.
public struct SourceFingerprint: Codable, Sendable, Equatable {
    /// File size in bytes.
    public var byteCount: Int64
    public var duration: Tick

    public init(byteCount: Int64, duration: Tick) {
        self.byteCount = byteCount
        self.duration = duration
    }

    /// Reads the size and duration of the file at `url`.
    public static func of(_ url: URL) async throws -> SourceFingerprint {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let duration = try await AVURLAsset(url: url).load(.duration)
        return SourceFingerprint(byteCount: Int64(size), duration: Ticks.from(duration))
    }
}
