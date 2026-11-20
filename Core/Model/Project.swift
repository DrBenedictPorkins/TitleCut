import CoreGraphics
import Foundation

/// The whole edit. A value type; `ProjectStore` is the only thing that mutates it.
public struct Project: Codable, Sendable, Equatable {
    /// Highest format this build reads and the format it writes.
    public static let currentFormatVersion = 1

    public var formatVersion: Int = Project.currentFormatVersion
    /// Identifies the project across renames, for MCP clients. Files saved
    /// before it existed get a new one when read; it is saved with them next.
    public var id: UUID
    /// `nil` until a video is chosen for a new document. It sets the
    /// output's size and frame rate; clips with no `sourceID` play it.
    public var source: SourceVideo?
    /// Videos added after the first (Add Video), in the order added. Clips
    /// name theirs with `VideoSegment.sourceID`; one no clip plays is
    /// removed. Absent in projects saved before it existed.
    public var addedSources: [SourceVideo]
    /// Played in order.
    public var segments: [Segment]
    public var titles: [Title]
    /// Styles used by this project (embedded copies, §5.2).
    public var styles: [TitleStyle]
    /// Images captured into the package `stills/` folder.
    public var stills: [StillImage]
    public var output: OutputSettings
    /// The music strip, in start order. Absent in projects saved before it
    /// existed; those read as empty.
    public var music: [MusicClip]

    public init(
        id: UUID = UUID(),
        source: SourceVideo? = nil,
        addedSources: [SourceVideo] = [],
        segments: [Segment] = [],
        titles: [Title] = [],
        styles: [TitleStyle] = [],
        stills: [StillImage] = [],
        output: OutputSettings = .default,
        music: [MusicClip] = []
    ) {
        self.id = id
        self.source = source
        self.addedSources = addedSources
        self.segments = segments
        self.titles = titles
        self.styles = styles
        self.stills = stills
        self.output = output
        self.music = music
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, source, addedSources, segments, titles, styles, stills, output, music
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decodeIfPresent(SourceVideo.self, forKey: .source)
        addedSources = try container.decodeIfPresent([SourceVideo].self, forKey: .addedSources)
            ?? []
        segments = try container.decode([Segment].self, forKey: .segments)
        titles = try container.decode([Title].self, forKey: .titles)
        styles = try container.decode([TitleStyle].self, forKey: .styles)
        stills = try container.decode([StillImage].self, forKey: .stills)
        output = try container.decode(OutputSettings.self, forKey: .output)
        music = try container.decodeIfPresent([MusicClip].self, forKey: .music) ?? []
    }

    /// A new document: no video, nothing on the timeline, a new ID.
    public static var empty: Project { Project() }

    /// The video `sourceID` names: `source` for `nil`, else an added one.
    public func source(id sourceID: UUID?) -> SourceVideo? {
        guard let sourceID else { return source }
        return addedSources.first { $0.id == sourceID }
    }

    /// The video `clip` plays.
    public func source(of clip: VideoSegment) -> SourceVideo? {
        source(id: clip.sourceID)
    }

    /// Every video with the key clips use for it (`VideoSegment.sourceID`):
    /// `nil` for `source`, then the added ones.
    public var sourcesByKey: [(key: UUID?, video: SourceVideo)] {
        (source.map { [(key: UUID?.none, video: $0)] } ?? [])
            + addedSources.map { (key: UUID?.some($0.id), video: $0) }
    }

    /// The keys of the videos the timeline plays, in the order of `sourcesByKey`.
    public var usedSourceKeys: [UUID?] {
        let used = Set(segments.compactMap { segment -> UUID?? in
            if case .video(let video) = segment { .some(video.sourceID) } else { nil }
        })
        return sourcesByKey.map(\.key).filter { used.contains($0) }
    }
}

/// The referenced original video (D6: not copied into the package).
public struct SourceVideo: Codable, Sendable, Equatable {
    /// Names an added video for the clips that play it. Files saved
    /// before it existed get a new one when read.
    public var id: UUID
    /// Plain (not security-scoped) file bookmark; the app is unsandboxed (D5).
    public var bookmark: Data
    public var lastKnownPath: String
    public var duration: Tick
    /// Size as displayed, after the track's preferred transform. (Projects
    /// saved before 2026-10-14 hold the stored size, before rotation.)
    public var naturalSize: CGSize
    /// Nominal frames per second, for frame step and timecode.
    public var frameRate: Double

    public init(id: UUID = UUID(), bookmark: Data, lastKnownPath: String, duration: Tick,
                naturalSize: CGSize, frameRate: Double) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.duration = duration
        self.naturalSize = naturalSize
        self.frameRate = frameRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookmark, lastKnownPath, duration, naturalSize, frameRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        duration = try container.decode(Tick.self, forKey: .duration)
        naturalSize = try container.decode(CGSize.self, forKey: .naturalSize)
        frameRate = try container.decode(Double.self, forKey: .frameRate)
    }
}

/// An image stored in the package at `stills/<fileName>`.
public struct StillImage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// `stills/<id>.png` inside the package.
    public var fileName: String
    /// Source time it was grabbed from, if any.
    public var capturedAt: Tick?
    public var pixelSize: CGSize

    public init(id: UUID, fileName: String, capturedAt: Tick?, pixelSize: CGSize) {
        self.id = id
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.pixelSize = pixelSize
    }
}

public struct OutputSettings: Codable, Sendable, Equatable {
    /// Defaults to the source natural size.
    public var size: CGSize
    /// Defaults to the source frame rate.
    public var frameRate: Double
    public var codec: Codec

    public init(size: CGSize, frameRate: Double, codec: Codec) {
        self.size = size
        self.frameRate = frameRate
        self.codec = codec
    }

    /// Placeholder until a source is set; replaced from the source on open.
    public static let `default` = OutputSettings(size: .zero, frameRate: 30, codec: .h264)
}

public enum Codec: String, Codable, Sendable, Equatable {
    case h264
    case hevc
}
