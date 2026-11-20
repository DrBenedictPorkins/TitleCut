import Foundation

extension Easing {
    /// Maps linear progress `t` (clamped to 0...1) onto this curve.
    /// Cubic curves; every one maps 0 to 0 and 1 to 1.
    public func value(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            let u = 1 - t
            return 1 - u * u * u
        case .easeInOut:
            if t < 0.5 { return 4 * t * t * t }
            let u = -2 * t + 2
            return 1 - u * u * u / 2
        }
    }
}
