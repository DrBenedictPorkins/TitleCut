import Foundation

/// Keeps at most one seek in flight and remembers only the latest request.
///
/// Usage: call ``request(_:)`` for every new target; if it returns a value,
/// issue that seek. When a seek finishes, call ``complete()``; if it returns
/// a value, issue that seek next. Intermediate targets are dropped.
public struct SeekCoalescer<Target: Sendable>: Sendable {
    /// Whether a seek has been issued and has not completed.
    public private(set) var isSeeking = false
    /// The latest target requested while a seek was in flight.
    public private(set) var pending: Target?

    public init() {}

    /// Records a seek target.
    /// - Returns: The target to issue now, or `nil` if it was queued.
    public mutating func request(_ target: Target) -> Target? {
        if isSeeking {
            pending = target
            return nil
        }
        isSeeking = true
        return target
    }

    /// Marks the in-flight seek as finished.
    /// - Returns: The queued target to issue next, or `nil` if idle.
    public mutating func complete() -> Target? {
        if let next = pending {
            pending = nil
            return next
        }
        isSeeking = false
        return nil
    }

    /// Drops all state, for example when the player item changes.
    public mutating func reset() {
        isSeeking = false
        pending = nil
    }
}
