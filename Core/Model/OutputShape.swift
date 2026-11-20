import CoreGraphics

/// Frame shapes offered for the output. Each is sized from the source's
/// short side, so a 1920x1080 source gives 1080x1920 portrait and 1080x1080
/// square. The video fills the frame, cropped at the centre (`FrameRenderer`).
public enum OutputShape: String, CaseIterable, Sendable {
    /// The source's own size.
    case original
    case landscape
    case portrait
    case square

    public var label: String {
        switch self {
        case .original: "Original"
        case .landscape: "16:9"
        case .portrait: "9:16"
        case .square: "1:1"
        }
    }

    /// Output size for `source`, in even pixels as H.264 and HEVC require.
    public func size(for source: SourceVideo) -> CGSize {
        let natural = source.naturalSize
        let short = min(natural.width, natural.height)
        let long = Self.even(short * 16 / 9)
        switch self {
        case .original: return natural
        case .landscape: return CGSize(width: long, height: Self.even(short))
        case .portrait: return CGSize(width: Self.even(short), height: long)
        case .square: return CGSize(width: Self.even(short), height: Self.even(short))
        }
    }

    /// The shapes to offer for `source`: Original first, then the three
    /// fixed shapes, even when the source is one of them.
    public static func offered(for source: SourceVideo) -> [OutputShape] {
        [.original, .landscape, .portrait, .square]
    }

    /// The offered shape `size` has, if any. Original wins when a fixed
    /// shape is the source's own.
    public static func of(_ size: CGSize, source: SourceVideo) -> OutputShape? {
        offered(for: source).first { sameAspect($0.size(for: source), size) }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        (value / 2).rounded() * 2
    }

    private static func sameAspect(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        return abs(a.width / a.height - b.width / b.height) < 0.01
    }
}
