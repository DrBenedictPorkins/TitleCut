import CoreImage

/// Draws one output frame (§6.3). Pure Core Image: callable from the
/// compositor, from tests, and later from the MCP `render_frame` tool.
///
/// Step 1 is the base: the source frame with its preferred transform,
/// scaled to fill the output size and cropped at the centre, so vertical and
/// square output crop the sides. At the source's own shape nothing is cropped. Step 2 composites the
/// active titles over it. No zoom yet.
public enum FrameRenderer {
    /// - Parameters:
    ///   - source: The decoded source frame, as stored (before rotation).
    ///   - preferredTransform: The source track's preferred transform, in
    ///     AVFoundation's top-left-origin coordinates.
    ///   - renderSize: Output size in pixels.
    ///   - frame: Where the frame sits on the picture and how far it zooms
    ///     in (`ClipFraming`).
    ///   - split: When set, each half of the frame (`SplitScreen.halves`)
    ///     shows the picture filled to that half with its own framing, and
    ///     `frame` is unused.
    /// - Returns: An image whose extent is exactly `(0, 0, renderSize)`.
    public static func render(source: CIImage, preferredTransform: CGAffineTransform,
                              renderSize: CGSize, frame: ClipFraming = .centred,
                              split: SplitScreen? = nil) -> CIImage {
        let oriented = applyPreferredTransform(preferredTransform, to: source)
        let canvas = CGRect(origin: .zero, size: renderSize)
        var fitted = CIImage.empty()
        if let split {
            for (index, half) in SplitScreen.halves(of: renderSize).enumerated() {
                // Core Image's origin is bottom-left.
                let part = aspectFill(oriented, in: half.size, frame: split[index])
                    .cropped(to: CGRect(origin: .zero, size: half.size))
                    .transformed(by: CGAffineTransform(
                        translationX: half.minX, y: renderSize.height - half.maxY))
                fitted = part.composited(over: fitted)
            }
        } else {
            fitted = aspectFill(oriented, in: renderSize, frame: frame)
        }
        return fitted
            .composited(over: CIImage(color: .black).cropped(to: canvas))
            .cropped(to: canvas)
    }

    /// Black frame of `renderSize`, for segments that have nothing to draw yet.
    public static func black(renderSize: CGSize) -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// A title card's colour over black, filling the frame.
    public static func solid(_ color: RGBA, renderSize: CGSize) -> CIImage {
        // The compositor does no colour management, so components pass through as sRGB.
        let fill = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue,
                                          alpha: color.alpha))
        return fill.composited(over: CIImage(color: .black))
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// `image` and `other` mixed, `amount` of the way to `other` (0...1),
    /// for clip transitions.
    public static func mix(_ image: CIImage, with other: CIImage, amount: Double) -> CIImage {
        let amount = min(max(amount, 0), 1)
        if amount <= 0 { return image }
        if amount >= 1 { return other }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: other,
            kCIInputTimeKey: amount,
        ]).cropped(to: image.extent)
    }

    // MARK: Titles (step 2)

    /// A title with everything needed to draw it: its effective style and its
    /// clamped output range.
    public struct TitleLayer: Sendable, Equatable {
        public var title: Title
        /// The project style `title.styleID` refers to; overrides not applied.
        public var style: TitleStyle
        /// From `TimelineMath.titleOutputRange`.
        public var outputRange: TickRange

        public init(title: Title, style: TitleStyle, outputRange: TickRange) {
            self.title = title
            self.style = style
            self.outputRange = outputRange
        }
    }

    /// Fraction of the render size kept clear at the edges by the preset positions.
    public static let safeMargin = 0.05

    /// Composites the layers active at `outputTime` over `base`, in start-time
    /// order (later starts on top; ties keep array order).
    ///
    /// - Parameter outputTime: Output time in ticks; fractional values come
    ///   from frame times that are not whole ticks (NTSC rates).
    /// - Returns: An image whose extent is exactly `(0, 0, renderSize)`.
    public static func composite(_ layers: [TitleLayer], over base: CIImage, at outputTime: Double,
                                 renderSize: CGSize, titleRenderer: TitleRenderer) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let ordered = layers.enumerated()
            .sorted { ($0.element.outputRange.start, $0.offset) < ($1.element.outputRange.start, $1.offset) }
            .map(\.element)
        var image = base
        for layer in ordered {
            guard let appearance = TransitionEvaluator.appearance(
                of: layer.title, outputRange: layer.outputRange, at: outputTime),
                appearance.opacity > 0.001, appearance.scale > 0.001,
                let rendered = titleRenderer.render(
                    layer.title, style: layer.style, renderSize: renderSize,
                    visibleCharacters: appearance.visibleCharacters,
                    highlightedWord: appearance.highlightedWord)
            else { continue }
            let style = layer.style.applying(layer.title.styleOverrides)
            image = titleImage(rendered, style: style, appearance: appearance,
                               renderSize: renderSize).composited(over: image)
        }
        return image.cropped(to: canvas)
    }

    /// Where a title box of `contentSize` sits on a frame of `renderSize`, in
    /// pixels with a top-left origin, before any transition. For hit-testing
    /// as well as drawing.
    ///
    /// `.custom(x, y)` centres the box on that point. The presets place it
    /// vertically (top edge at the top margin; centred; bottom edge at 85 %
    /// for the lower third; bottom edge at the bottom margin) and horizontally
    /// by the style's alignment (left margin, centre, right margin).
    public static func titleFrame(contentSize: CGSize, position: NormalizedPosition,
                                  alignment: TextAlignment, renderSize: CGSize) -> CGRect {
        let w = renderSize.width, h = renderSize.height
        let size = contentSize
        if case let .custom(x, y) = position {
            return CGRect(x: x * w - size.width / 2, y: y * h - size.height / 2,
                          width: size.width, height: size.height)
        }
        let aligned: Double = switch alignment {
        case .leading: safeMargin * w
        case .center: (w - size.width) / 2
        case .trailing: (1 - safeMargin) * w - size.width
        }
        // A box too wide for the margins moves in so it stays on the frame.
        let left = size.width <= w ? min(max(aligned, 0), w - size.width) : aligned
        let top: Double = switch position {
        case .top: safeMargin * h
        case .center: (h - size.height) / 2
        case .lowerThird: 0.85 * h - size.height
        case .bottom: (1 - safeMargin) * h - size.height
        case .custom: 0
        }
        return CGRect(x: left, y: top, width: size.width, height: size.height)
    }

    /// The normalised x centre that puts a box `contentWidth` wide where
    /// `alignment` puts preset titles: at the left margin, centred, or at the
    /// right margin. ALIGN uses it to move a title with a custom position.
    public static func alignedCentreX(contentWidth: CGFloat, alignment: TextAlignment,
                                      renderWidth: CGFloat) -> Double {
        guard renderWidth > 0 else { return 0.5 }
        let half = Double(contentWidth / renderWidth) / 2
        return switch alignment {
        case .leading: safeMargin + half
        case .center: 0.5
        case .trailing: 1 - safeMargin - half
        }
    }

    /// Commands that move each of `titles` with a custom position across to
    /// where `alignment` puts it, keeping its height; titles on a preset
    /// position need none, since the preset follows the alignment.
    public static func alignmentMoves(_ titles: [Title], to alignment: TextAlignment,
                                      style: (Title) -> TitleStyle?, renderer: TitleRenderer,
                                      renderSize: CGSize) -> [ProjectCommand] {
        titles.compactMap { title in
            guard let style = style(title),
                  case let .custom(x, y) = style.applying(title.styleOverrides).position,
                  let rendered = renderer.render(title, style: style, renderSize: renderSize)
            else { return nil }
            let newX = alignedCentreX(contentWidth: rendered.contentRect.width,
                                      alignment: alignment, renderWidth: renderSize.width)
            guard abs(newX - x) > 0.0001 else { return nil }
            var overrides = title.styleOverrides ?? StyleOverrides()
            overrides.position = .custom(x: newX, y: y)
            return .setTitleStyleOverrides(id: title.id, overrides: overrides)
        }
    }

    /// The title bitmap faded, scaled about its centre and moved into place,
    /// in bottom-left-origin render coordinates.
    private static func titleImage(_ rendered: RenderedTitle, style: TitleStyle,
                                   appearance: TitleAppearance, renderSize: CGSize) -> CIImage {
        let content = rendered.contentRect
        let frame = titleFrame(contentSize: content.size, position: style.position,
                               alignment: style.alignment, renderSize: renderSize)
        // Target centre in bottom-left coordinates, offset applied (offset is y-down).
        var centre = CGPoint(x: frame.midX + appearance.offset.dx * renderSize.width,
                             y: renderSize.height - frame.midY
                                - appearance.offset.dy * renderSize.height)
        let scale = appearance.scale
        if scale == 1 {
            // Whole-pixel placement keeps unscaled text crisp.
            centre.x = (centre.x - content.width / 2).rounded() + content.width / 2
            centre.y = (centre.y - content.height / 2).rounded() + content.height / 2
        }

        var image = CIImage(cgImage: rendered.image)
        if appearance.opacity < 1 {
            let opacity = CGFloat(max(appearance.opacity, 0))
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        if scale != 1 { image = image.samplingLinear() }
        let transform = CGAffineTransform(translationX: -content.midX, y: -content.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        return image.transformed(by: transform)
    }

    /// Applies a top-left-origin transform to a bottom-left-origin `CIImage`
    /// and moves the result back to the origin.
    static func applyPreferredTransform(_ transform: CGAffineTransform,
                                        to image: CIImage) -> CIImage {
        guard !transform.isIdentity else { return image.translatedToOrigin() }
        let height = image.extent.height
        // Into top-left space: y' = height - y.
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let transformed = image.translatedToOrigin()
            .transformed(by: toTopLeft)
            .transformed(by: transform)
        // Back to bottom-left space: flip y, then move the extent to the origin.
        return transformed
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
            .translatedToOrigin()
    }

    /// Scales `image` uniformly to fit `size` and centres it on whole pixels.
    static func aspectFit(_ image: CIImage, in size: CGSize) -> CIImage {
        aspectScale(image, in: size, fill: false)
    }

    /// Scales `image` uniformly to cover `size`, `frame.zoom` times more,
    /// and places it on whole pixels by `frame`; the caller crops what
    /// overhangs.
    static func aspectFill(_ image: CIImage, in size: CGSize,
                           frame: ClipFraming = .centred) -> CIImage {
        aspectScale(image, in: size, fill: true, frame: frame)
    }

    private static func aspectScale(_ image: CIImage, in size: CGSize, fill: Bool,
                                    frame: ClipFraming = .centred) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else {
            return image
        }
        let widthScale = size.width / extent.width
        let heightScale = size.height / extent.height
        let frame = frame.clamped
        let scale = fill ? max(widthScale, heightScale) * frame.zoom
                         : min(widthScale, heightScale)
        let scaled = scale == 1
            ? image
            : image.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Core Image's origin is bottom-left: y 0 shows the picture's top.
        let x = ((size.width - extent.width * scale) * frame.x).rounded()
        let y = fill ? ((size.height - extent.height * scale) * (1 - frame.y)).rounded()
                     : ((size.height - extent.height * scale) / 2).rounded()
        return scaled.translatedToOrigin()
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

private extension CIImage {
    func translatedToOrigin() -> CIImage {
        let origin = extent.origin
        guard origin != .zero else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
