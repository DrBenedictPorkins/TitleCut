import CoreGraphics

/// The part of a display a screen recording captures.
public enum ScreenRegion {
    /// `region`, in a screen's own points with the origin at the bottom left
    /// (AppKit), as ScreenCaptureKit takes it: the display's points with the
    /// origin at the top left, clamped to the screen.
    public static func displayRect(_ region: CGRect, screenSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: screenSize)
        let clamped = region.standardized.intersection(bounds)
        guard !clamped.isNull else { return .zero }
        return CGRect(x: clamped.minX, y: screenSize.height - clamped.maxY,
                      width: clamped.width, height: clamped.height)
    }

    /// The recording's size in pixels for `points` on a screen with `scale`
    /// pixels per point: whole and even, as H.264 needs, and at least 2.
    public static func pixelSize(_ points: CGSize, scale: CGFloat) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(points.width), height: even(points.height))
    }
}
