import CoreGraphics
import Foundation
import TitleCutCore

/// Finds the title under a click on the preview, using the same layout the
/// compositor draws with (`TitleRenderer` content box placed by
/// `FrameRenderer.titleFrame`). Transitions are ignored: the resting frame
/// is the target.
enum PreviewHitTest {
    /// - Parameters:
    ///   - point: Render-size pixels, top-left origin.
    ///   - outputTime: Playhead in ticks.
    /// - Returns: The topmost title on screen at `outputTime` containing `point`.
    static func title(at point: CGPoint, in project: Project, outputTime: Tick,
                      renderSize: CGSize, renderer: TitleRenderer) -> UUID? {
        hit(at: point, in: project, outputTime: outputTime,
            renderSize: renderSize, renderer: renderer)?.id
    }

    /// Like `title(at:)`, also returning the title's resting frame in
    /// render-size pixels, top-left origin.
    static func hit(at point: CGPoint, in project: Project, outputTime: Tick,
                    renderSize: CGSize, renderer: TitleRenderer) -> (id: UUID, frame: CGRect)? {
        // Drawing order: later starts on top, ties keep array order.
        let layers = CompositionBuilder.titleLayers(project)
            .enumerated()
            .filter { $0.element.outputRange.contains(outputTime) }
            .sorted { ($0.element.outputRange.start, $0.offset)
                      < ($1.element.outputRange.start, $1.offset) }
            .map(\.element)
        for layer in layers.reversed() {
            guard let rendered = renderer.render(layer.title, style: layer.style,
                                                 renderSize: renderSize) else { continue }
            let style = layer.style.applying(layer.title.styleOverrides)
            let frame = FrameRenderer.titleFrame(contentSize: rendered.contentRect.size,
                                                 position: style.position,
                                                 alignment: style.alignment,
                                                 renderSize: renderSize)
            if frame.insetBy(dx: -6, dy: -6).contains(point) { return (layer.title.id, frame) }
        }
        return nil
    }
}
