import Foundation

/// The visible part of the timeline: zoom and horizontal scroll (§7.3).
///
/// View state only; not saved, not undoable. Widths are in points, times in
/// ticks. At fit (the default and the widest zoom) the whole timeline fills
/// the track width and there is nothing to scroll.
public struct TimelineViewport: Equatable, Sendable {
    /// `nil` at fit; otherwise held as the timeline length changes.
    public var ticksPerPoint: Double?
    /// Output time at the track's left edge. Clamped when read.
    public var start: Double = 0

    /// Narrowest zoom: one frame spans this many points.
    public static let pointsPerFrameAtMaximum: Double = 8

    public init(ticksPerPoint: Double? = nil, start: Double = 0) {
        self.ticksPerPoint = ticksPerPoint
        self.start = start
    }

    public var isFit: Bool { ticksPerPoint == nil }

    /// Ticks per point that fit `total` into `width`; 0 for an empty timeline.
    public static func fitTicksPerPoint(total: Tick, width: Double) -> Double {
        total > 0 && width > 0 ? Double(total) / width : 0
    }

    /// Ticks per point at the closest zoom.
    public static func minimumTicksPerPoint(frameRate: Double) -> Double {
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : Timecode.fallbackFrameRate
        return Double(Ticks.perSecond) / rate / pointsPerFrameAtMaximum
    }

    /// The scale in use: the held zoom, never wider than fit nor closer than
    /// one frame per `pointsPerFrameAtMaximum`.
    public func resolvedTicksPerPoint(total: Tick, width: Double, frameRate: Double) -> Double {
        let fit = Self.fitTicksPerPoint(total: total, width: width)
        guard let ticksPerPoint, fit > 0 else { return fit }
        let closest = min(Self.minimumTicksPerPoint(frameRate: frameRate), fit)
        return min(max(ticksPerPoint, closest), fit)
    }

    /// `start`, clamped so the track never shows past either end.
    public func resolvedStart(total: Tick, width: Double, frameRate: Double) -> Double {
        let scale = resolvedTicksPerPoint(total: total, width: width, frameRate: frameRate)
        let latest = max(Double(total) - width * scale, 0)
        return min(max(start, 0), latest)
    }

    /// Output times at the track's left and right edges.
    public func visibleRange(total: Tick, width: Double,
                             frameRate: Double) -> ClosedRange<Double> {
        let scale = resolvedTicksPerPoint(total: total, width: width, frameRate: frameRate)
        let first = resolvedStart(total: total, width: width, frameRate: frameRate)
        return first...(first + width * scale)
    }

    /// Zooms in by `factor` (below 1 zooms out), keeping `anchorTick` at
    /// `anchorX` points from the track's left edge. Reaching fit returns to fit.
    public mutating func zoom(by factor: Double, anchorTick: Double, anchorX: Double,
                              total: Tick, width: Double, frameRate: Double) {
        let fit = Self.fitTicksPerPoint(total: total, width: width)
        guard factor > 0, factor.isFinite, fit > 0 else { return }
        let current = resolvedTicksPerPoint(total: total, width: width, frameRate: frameRate)
        let closest = min(Self.minimumTicksPerPoint(frameRate: frameRate), fit)
        let next = min(max(current / factor, closest), fit)
        if next >= fit {
            zoomToFit()
            return
        }
        ticksPerPoint = next
        start = anchorTick - anchorX * next
        start = resolvedStart(total: total, width: width, frameRate: frameRate)
    }

    /// Zoom factor for a Command-scroll of `delta` toward the person's away
    /// direction (positive zooms in). Exponential, so equal deltas give equal
    /// steps: a wheel notch (one line) is about 12%, and a trackpad swipe of
    /// 100 points about 2.7x.
    public static func zoomFactor(scrollDelta delta: Double, isPrecise: Bool) -> Double {
        guard delta.isFinite else { return 1 }
        return exp(delta * (isPrecise ? 0.01 : 0.12))
    }

    public mutating func zoomToFit() {
        ticksPerPoint = nil
        start = 0
    }

    /// Scrolls by `points`; positive moves later in time.
    public mutating func scroll(byPoints points: Double, total: Tick, width: Double,
                                frameRate: Double) {
        let scale = resolvedTicksPerPoint(total: total, width: width, frameRate: frameRate)
        start = resolvedStart(total: total, width: width, frameRate: frameRate) + points * scale
        start = resolvedStart(total: total, width: width, frameRate: frameRate)
    }

    /// Pages so `tick` is visible: if it is outside the visible range, it
    /// becomes the left edge (clamped). Returns whether the view moved.
    @discardableResult
    public mutating func reveal(_ tick: Double, total: Tick, width: Double,
                                frameRate: Double) -> Bool {
        let visible = visibleRange(total: total, width: width, frameRate: frameRate)
        guard tick < visible.lowerBound || tick >= visible.upperBound else { return false }
        let before = visible.lowerBound
        start = tick
        start = resolvedStart(total: total, width: width, frameRate: frameRate)
        return start != before
    }

    // MARK: Ruler

    /// Ruler tick spacing in ticks: the smallest of 1, 2, 5 or 10 frames, or
    /// 1, 2, 5, 10, 15 or 30 seconds, or 1, 2, 5, 10, 15 or 30 minutes, or
    /// 1, 2, 5 or 10 hours, that puts labels at least `minimumSpacing`
    /// points apart.
    public static func rulerStep(ticksPerPoint: Double, frameRate: Double,
                                 minimumSpacing: Double = 56) -> Double {
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : Timecode.fallbackFrameRate
        let second = Double(Ticks.perSecond)
        let frame = second / rate
        let steps = [1, 2, 5, 10].map { $0 * frame }
            + [1, 2, 5, 10, 15, 30].map { $0 * second }
            + [1, 2, 5, 10, 15, 30].map { $0 * 60 * second }
            + [1, 2, 5, 10].map { $0 * 3600 * second }
        let needed = ticksPerPoint * minimumSpacing
        return steps.first { $0 >= needed } ?? steps[steps.count - 1]
    }

    /// Ruler label for `tick`: `m:ss`, `h:mm:ss` past an hour, and a
    /// `:ff` frame field when `step` is shorter than a second.
    public static func rulerLabel(_ tick: Double, step: Double, frameRate: Double) -> String {
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : Timecode.fallbackFrameRate
        let seconds = max(tick, 0) / Double(Ticks.perSecond)
        // Round to the nearest frame so float error cannot drop a frame.
        let frames = Int((seconds * rate).rounded())
        let perSecond = Int(rate.rounded())
        let whole = frames / max(perSecond, 1)
        let frame = frames % max(perSecond, 1)
        let hours = whole / 3600, minutes = (whole / 60) % 60, secs = whole % 60
        var label = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                              : String(format: "%d:%02d", minutes, secs)
        if step < Double(Ticks.perSecond) { label += String(format: ":%02d", frame) }
        return label
    }
}
