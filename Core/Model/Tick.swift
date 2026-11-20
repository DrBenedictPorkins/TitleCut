import CoreMedia
import Foundation

/// Model time unit: 1/600 s. Divisible by 24, 25, 30 and 60 fps.
public typealias Tick = Int64

/// Conversions between `Tick`, seconds and `CMTime`.
public enum Ticks {
    /// Ticks per second; also the `CMTime` timescale used at the AVFoundation boundary.
    public static let perSecond: Tick = 600
    public static let timescale: CMTimeScale = 600

    /// Nearest tick to `seconds`. Non-finite values map to 0.
    public static func from(seconds: Double) -> Tick {
        guard seconds.isFinite else { return 0 }
        return Tick((seconds * Double(perSecond)).rounded())
    }

    public static func seconds(_ ticks: Tick) -> Double {
        Double(ticks) / Double(perSecond)
    }

    /// Converts a `CMTime`, rounding toward zero so a duration never exceeds its source.
    public static func from(_ time: CMTime) -> Tick {
        guard time.isNumeric else { return 0 }
        return CMTimeConvertScale(time, timescale: timescale, method: .roundTowardZero).value
    }

    public static func cmTime(_ ticks: Tick) -> CMTime {
        CMTime(value: ticks, timescale: timescale)
    }
}

/// Half-open range `[start, start + duration)` in ticks.
public struct TickRange: Codable, Sendable, Equatable, Hashable {
    public var start: Tick
    public var duration: Tick

    public init(start: Tick, duration: Tick) {
        self.start = start
        self.duration = duration
    }

    public var end: Tick { start + duration }

    /// `true` when `start <= tick < end`.
    public func contains(_ tick: Tick) -> Bool {
        tick >= start && tick < end
    }

    public var cmTimeRange: CMTimeRange {
        CMTimeRange(start: Ticks.cmTime(start), duration: Ticks.cmTime(duration))
    }
}
