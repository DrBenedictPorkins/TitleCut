import CoreGraphics
import Foundation

/// One block of the output timeline.
public enum Segment: Codable, Sendable, Equatable, Identifiable {
    case video(VideoSegment)
    case still(StillSegment)
    /// A title card: solid colour, silent.
    case card(CardSegment)
    /// Empty time: black, silent.
    case gap(GapSegment)

    public var id: UUID {
        switch self {
        case .video(let segment): segment.id
        case .still(let segment): segment.id
        case .card(let segment): segment.id
        case .gap(let segment): segment.id
        }
    }

    public var isGap: Bool {
        if case .gap = self { true } else { false }
    }

    /// Encodes as `{"video": {...}}`, `{"still": {...}}`, `{"card": {...}}` or
    /// `{"gap": {...}}`, the payload directly under the case key (no
    /// synthesized `_0` wrapper).
    private enum CodingKeys: String, CodingKey {
        case video, still, card, gap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription:
                    "A segment must have exactly one of \"video\", \"still\", \"card\" "
                    + "or \"gap\"."))
        }
        switch key {
        case .video: self = .video(try container.decode(VideoSegment.self, forKey: .video))
        case .still: self = .still(try container.decode(StillSegment.self, forKey: .still))
        case .card: self = .card(try container.decode(CardSegment.self, forKey: .card))
        case .gap: self = .gap(try container.decode(GapSegment.self, forKey: .gap))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let segment): try container.encode(segment, forKey: .video)
        case .still(let segment): try container.encode(segment, forKey: .still)
        case .card(let segment): try container.encode(segment, forKey: .card)
        case .gap(let segment): try container.encode(segment, forKey: .gap)
        }
    }

    /// Length on the output timeline.
    public var duration: Tick {
        switch self {
        case .video(let segment): segment.outputDuration
        case .still(let segment): segment.duration
        case .card(let segment): segment.duration
        case .gap(let segment): segment.duration
        }
    }
}

public struct VideoSegment: Codable, Sendable, Equatable {
    public var id: UUID
    /// The added video it plays (`Project.addedSources`); `nil` plays
    /// `Project.source`. Absent from older files.
    public var sourceID: UUID?
    /// Range in the source video.
    public var sourceRange: TickRange
    /// Where the output frame sits across the picture when the output is
    /// narrower than the source (e.g. 9:16 from 16:9): 0 shows the left edge,
    /// 1 the right edge. `nil` is centred.
    public var framing: Double?
    /// As `framing`, down a picture taller than the frame: 0 shows the top
    /// edge, 1 the bottom. `nil` is centred. Absent from older files.
    public var framingY: Double?
    /// How far the frame is zoomed into the picture, 1...`ClipFraming
    /// .maximumZoom`; `nil` is 1. Absent from older files.
    public var zoom: Double?
    /// Two parts of the picture at once, each filling half the frame;
    /// `framing`, `framingY` and `zoom` are then unused. `nil` shows one.
    /// Absent from older files.
    public var split: SplitScreen?
    /// At the cut before it (`ClipTransition`). Absent from older files.
    public var transitionIn: ClipTransition?
    /// At the video's end, on the last segment only.
    public var transitionOut: ClipTransition?
    /// Playback speed, one of `speeds`; `nil` is normal speed. Speech keeps
    /// its pitch. Absent from older files.
    public var speed: Double?
    /// Gain on the clip's sound, 0...`maximumVolume`; `nil` is 1. Absent
    /// from older files.
    public var volume: Double?

    public static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 10]
    public static let maximumVolume = 2.0

    public init(id: UUID, sourceID: UUID? = nil, sourceRange: TickRange,
                framing: Double? = nil, split: SplitScreen? = nil,
                transitionIn: ClipTransition? = nil, transitionOut: ClipTransition? = nil,
                speed: Double? = nil, volume: Double? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.framing = framing
        self.split = split
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.speed = speed
        self.volume = volume
    }

    /// `framing`, `framingY` and `zoom` together.
    public var frame: ClipFraming {
        get { ClipFraming(x: framing ?? 0.5, y: framingY ?? 0.5, zoom: zoom ?? 1) }
        set {
            let clamped = newValue.clamped
            framing = clamped.x == 0.5 && framing == nil ? nil : clamped.x
            framingY = clamped.y == 0.5 ? nil : clamped.y
            zoom = clamped.zoom == 1 ? nil : clamped.zoom
        }
    }

    /// Source time played per unit of output time.
    public var rate: Double { speed ?? 1 }

    /// Length on the output timeline: the source range played at `rate`.
    public var outputDuration: Tick { scaled(sourceRange.duration, by: 1 / rate) }

    /// Source ticks played in the first `offset` output ticks of the clip.
    public func sourceOffset(atOutput offset: Tick) -> Tick { scaled(offset, by: rate) }

    /// Output ticks from the clip's start to source time `time`.
    public func outputOffset(ofSource time: Tick) -> Tick {
        scaled(time - sourceRange.start, by: 1 / rate)
    }

    private func scaled(_ ticks: Tick, by factor: Double) -> Tick {
        factor == 1 ? ticks : Tick((Double(ticks) * factor).rounded())
    }
}

/// The part of a clip's picture a frame (or half of one) shows: the
/// picture is scaled to fill it, then `zoom` times more, and `x` and `y`
/// place it where it overhangs.
public struct ClipFraming: Codable, Sendable, Equatable {
    /// 0 shows the left edge, 1 the right, where the picture is wider.
    public var x: Double
    /// 0 shows the top edge, 1 the bottom, where the picture is taller.
    public var y: Double
    /// 1...`maximumZoom`.
    public var zoom: Double

    public static let maximumZoom = 6.0
    public static let centred = ClipFraming(x: 0.5)

    public init(x: Double, y: Double = 0.5, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    /// `x` and `y` in 0...1, `zoom` in 1...`maximumZoom`.
    public var clamped: ClipFraming {
        ClipFraming(x: min(max(x, 0), 1), y: min(max(y, 0), 1),
                    zoom: min(max(zoom, 1), Self.maximumZoom))
    }

    /// The part of a picture of `sourceSize` shown in a frame of `size`:
    /// normalised to the picture, top-left origin. The whole picture when
    /// the shapes match at zoom 1.
    public func visibleRect(sourceSize: CGSize, in size: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let fill = max(size.width / sourceSize.width, size.height / sourceSize.height)
        let scale = fill * min(max(zoom, 1), Self.maximumZoom)
        let width = min(size.width / (sourceSize.width * scale), 1)
        let height = min(size.height / (sourceSize.height * scale), 1)
        return CGRect(x: (1 - width) * min(max(x, 0), 1), y: (1 - height) * min(max(y, 0), 1),
                      width: width, height: height)
    }
}

/// A clip shown as two halves of the frame, each with its own framing:
/// stacked in a frame at least as tall as it is wide, side by side in a
/// wider one.
public struct SplitScreen: Codable, Sendable, Equatable {
    /// Framing of the top or left half.
    public var first: ClipFraming
    /// Framing of the bottom or right half.
    public var second: ClipFraming

    /// The left and right quarters, for two people facing each other.
    public init(first: ClipFraming = ClipFraming(x: 0.25),
                second: ClipFraming = ClipFraming(x: 0.75)) {
        self.first = first
        self.second = second
    }

    /// Framing of half 0 (`first`) or 1 (`second`).
    public subscript(half: Int) -> ClipFraming {
        get { half == 0 ? first : second }
        set { if half == 0 { first = newValue } else { second = newValue } }
    }

    private enum CodingKeys: String, CodingKey { case first, second }

    /// Files from before zoom (2026-10-19) store each half's framing as a
    /// number, its `x`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func half(_ key: CodingKeys) throws -> ClipFraming {
            if let x = try? container.decode(Double.self, forKey: key) { return ClipFraming(x: x) }
            return try container.decode(ClipFraming.self, forKey: key)
        }
        first = try half(.first)
        second = try half(.second)
    }

    /// Whether a frame of `size` is split top and bottom.
    public static func isStacked(_ size: CGSize) -> Bool { size.height >= size.width }

    /// The halves of a frame of `size` in whole pixels, first then second,
    /// with a top-left origin. An odd pixel goes to the second.
    public static func halves(of size: CGSize) -> [CGRect] {
        if isStacked(size) {
            let top = (size.height / 2).rounded(.down)
            return [CGRect(x: 0, y: 0, width: size.width, height: top),
                    CGRect(x: 0, y: top, width: size.width, height: size.height - top)]
        }
        let left = (size.width / 2).rounded(.down)
        return [CGRect(x: 0, y: 0, width: left, height: size.height),
                CGRect(x: left, y: 0, width: size.width - left, height: size.height)]
    }

    /// The size of the first half of a frame of `size`.
    public static func halfSize(of size: CGSize) -> CGSize { halves(of: size)[0].size }
}

public struct StillSegment: Codable, Sendable, Equatable {
    public var id: UUID
    /// Refers to `Project.stills`.
    public var stillID: UUID
    public var duration: Tick
    /// Empty means a static full frame.
    public var zoom: [ZoomKeyframe]
    /// As in `VideoSegment`.
    public var transitionIn: ClipTransition?
    public var transitionOut: ClipTransition?

    public init(id: UUID, stillID: UUID, duration: Tick, zoom: [ZoomKeyframe] = [],
                transitionIn: ClipTransition? = nil, transitionOut: ClipTransition? = nil) {
        self.id = id
        self.stillID = stillID
        self.duration = duration
        self.zoom = zoom
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
    }

    /// How long the camera's last view stays after its motion ends; 0
    /// without motion.
    public var hold: Tick {
        guard zoom.count > 1, let last = zoom.last else { return 0 }
        return max(duration - last.time, 0)
    }
}

/// A title card: a length of solid colour for titles to sit on, silent.
/// Moved, resized and given transitions like a freeze.
public struct CardSegment: Codable, Sendable, Equatable {
    public var id: UUID
    public var duration: Tick
    public var color: RGBA
    /// As in `VideoSegment`.
    public var transitionIn: ClipTransition?
    public var transitionOut: ClipTransition?

    public init(id: UUID, duration: Tick, color: RGBA = RGBA(red: 0, green: 0, blue: 0),
                transitionIn: ClipTransition? = nil, transitionOut: ClipTransition? = nil) {
        self.id = id
        self.duration = duration
        self.color = color
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
    }
}

/// Space between clips on the output timeline. Never last, never empty,
/// never next to another gap (`ProjectCommand` keeps it so).
public struct GapSegment: Codable, Sendable, Equatable {
    public var id: UUID
    public var duration: Tick
    /// At the cut before it, as in `VideoSegment`.
    public var transitionIn: ClipTransition?

    public init(id: UUID, duration: Tick, transitionIn: ClipTransition? = nil) {
        self.id = id
        self.duration = duration
        self.transitionIn = transitionIn
    }
}

/// Segment-agnostic so video segments can use it later (§4.4).
public struct ZoomKeyframe: Codable, Sendable, Equatable {
    /// Relative to segment start.
    public var time: Tick
    /// Normalised 0...1 in image space, origin top-left.
    public var center: CGPoint
    /// 1.0 = full frame, 2.0 = 2x zoom.
    public var scale: Double
    /// Easing into this keyframe.
    public var easing: Easing

    public init(time: Tick, center: CGPoint, scale: Double, easing: Easing) {
        self.time = time
        self.center = center
        self.scale = scale
        self.easing = easing
    }
}

public enum Easing: String, Codable, Sendable, Equatable {
    case linear, easeIn, easeOut, easeInOut
}
