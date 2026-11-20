import CoreGraphics
import Foundation

/// The "TitleCut" wordmark drawn across the middle of unpaid exports.
///
/// It is an ordinary title layer added by `CompositionBuilder` for the whole
/// output, so it goes through the same renderer as every other title. It
/// never enters the project, the preview or the timeline.
public enum Watermark {
    public static let text = "TitleCut"

    static let styleID = UUID(uuidString: "7C1E0001-0000-4000-8000-0000000000FF")!
    static let titleID = UUID(uuidString: "7C1E0002-0000-4000-8000-0000000000FF")!

    /// See-through white letters with a faint dark outline, so the mark
    /// reads on both light and dark footage.
    static func style(renderSize: CGSize) -> TitleStyle {
        // Fill about two thirds of the width on landscape video, and stay
        // inside the frame on portrait video. The wordmark is roughly 4.8
        // font sizes wide.
        let aspect = renderSize.height > 0 ? renderSize.width / renderSize.height : 16.0 / 9
        let fontSizeRatio = min(0.24, 0.16 * aspect)
        return TitleStyle(
            id: styleID, name: "Watermark", fontName: "Avenir Next",
            fontSizeRatio: fontSizeRatio, weight: .heavy,
            textColor: RGBA(red: 1, green: 1, blue: 1, alpha: 0.4),
            stroke: Stroke(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.18),
                           widthRatio: 0.012),
            alignment: .center, position: .center, maxWidthRatio: 1)
    }

    /// The wordmark over the whole output, `nil` for an empty project.
    static func layer(for project: Project, renderSize: CGSize) -> FrameRenderer.TitleLayer? {
        let total = TimelineMath.outputDuration(project)
        guard total > 0, let first = project.segments.first else { return nil }
        let title = Title(id: titleID, text: text,
                          anchor: TitleAnchor(segmentID: first.id, offset: 0),
                          duration: total, styleID: styleID)
        return FrameRenderer.TitleLayer(title: title, style: style(renderSize: renderSize),
                                        outputRange: TickRange(start: 0, duration: total))
    }
}
