import Foundation

/// Formats a time as `HH:MM:SS:FF` (non-drop-frame).
///
/// Hours, minutes and seconds follow the wall clock. The frame field is the
/// frame index within the current second at the given nominal rate, so for
/// 29.97 fps it runs 00...29.
public enum Timecode {
    /// Rate used when the source reports no usable frame rate.
    public static let fallbackFrameRate: Double = 30

    /// Tolerance, in frames, that absorbs floating-point error at frame edges.
    static let frameEpsilon: Double = 1e-4

    /// Returns `seconds` as `HH:MM:SS:FF` at `frameRate`.
    ///
    /// - Parameters:
    ///   - seconds: Time in seconds. Negative, NaN or infinite values format as zero.
    ///   - frameRate: Nominal frames per second. Values that are not positive
    ///     and finite fall back to ``fallbackFrameRate``.
    public static func string(seconds: Double, frameRate: Double) -> String {
        let parts = components(seconds: seconds, frameRate: frameRate)
        return String(format: "%02d:%02d:%02d:%02d",
                      parts.hours, parts.minutes, parts.seconds, parts.frames)
    }

    /// Splits a time into hours, minutes, seconds and frames.
    public static func components(
        seconds: Double, frameRate: Double
    ) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        let rate = (frameRate.isFinite && frameRate > 0) ? frameRate : fallbackFrameRate
        let time = (seconds.isFinite && seconds > 0) ? seconds : 0

        var whole = Int(time.rounded(.down))
        var frames = Int((time - Double(whole)) * rate + frameEpsilon)
        let framesPerSecond = Int(rate.rounded(.up))
        if frames >= framesPerSecond {
            // Within epsilon of the next second.
            if (time - Double(whole)) * rate + frameEpsilon >= rate {
                whole += 1
                frames = 0
            } else {
                frames = framesPerSecond - 1
            }
        }

        return (whole / 3600, (whole / 60) % 60, whole % 60, frames)
    }
}
