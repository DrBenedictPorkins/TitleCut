import CoreGraphics
import Foundation

/// How big an exported MP4 is: the project's own size and rate at the
/// highest quality, or scaled down to a longest side at no more than
/// `maximumFrameRate`, encoded at a set data rate so the file size is known
/// before export. Titles, framing and stills are sized relative to the
/// frame, so a smaller frame shows the same picture.
public enum ExportSize: String, CaseIterable, Sendable {
    case original, large, medium, small

    public var label: String {
        switch self {
        case .original: "Original"
        case .large: "Large"
        case .medium: "Medium"
        case .small: "Small"
        }
    }

    /// Longest side of the frame; `nil` keeps the project's size.
    public var longSide: CGFloat? {
        switch self {
        case .original: nil
        case .large: 1920
        case .medium: 1280
        case .small: 960
        }
    }

    /// Frame rate ceiling for the scaled sizes.
    public static let maximumFrameRate = 30.0

    /// AAC data rate of the scaled sizes, in bits per second.
    public static let audioBitRate = 128_000

    /// Encoded bits per pixel per frame: what H.264 and HEVC need to look
    /// clean on a phone screen.
    static func bitsPerPixel(_ codec: Codec) -> Double {
        switch codec {
        case .h264: 0.08
        case .hevc: 0.055
        }
    }

    /// `project` as this size exports it: the output frame scaled down to
    /// `longSide` (whole, even pixels) and the rate capped. Unchanged for
    /// `original`, or when the frame is already no larger.
    public func scaled(_ project: Project) -> Project {
        guard let longSide else { return project }
        var project = project
        let size = CompositionBuilder.renderSize(project)
        let factor = min(longSide / max(size.width, size.height), 1)
        func even(_ value: CGFloat) -> CGFloat { max((value * factor / 2).rounded() * 2, 2) }
        project.output.size = CGSize(width: even(size.width), height: even(size.height))
        project.output.frameRate = min(project.output.frameRate, Self.maximumFrameRate)
        return project
    }

    /// Video data rate for `project` (already `scaled`), in bits per second;
    /// `nil` for `original`.
    public func videoBitRate(for project: Project, codec: Codec) -> Int? {
        guard longSide != nil else { return nil }
        let size = CompositionBuilder.renderSize(project)
        let rate = min(project.output.frameRate, Self.maximumFrameRate)
        return Int(Double(size.width * size.height) * rate * Self.bitsPerPixel(codec))
    }

    /// About how many bytes the MP4 of `project` takes at this size; `nil`
    /// for `original`, whose size depends on the footage.
    public func estimatedBytes(of project: Project, codec: Codec) -> Int? {
        let scaled = scaled(project)
        guard let video = videoBitRate(for: scaled, codec: codec) else { return nil }
        let seconds = Ticks.seconds(TimelineMath.outputDuration(project))
        return Int(Double(video + Self.audioBitRate) * seconds / 8)
    }
}
