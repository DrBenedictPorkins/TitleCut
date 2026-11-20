import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// A title laid out and drawn into a bitmap.
public struct RenderedTitle: @unchecked Sendable {
    /// Premultiplied sRGB bitmap. Includes room for shadow and stroke.
    public let image: CGImage
    /// The title's box inside `image`, in pixels, bottom-left origin: the
    /// text plus background padding, without shadow or stroke margins. This
    /// is the rectangle that gets positioned on the frame.
    public let contentRect: CGRect
}

extension TitleStyle {
    /// The style with a title's overrides applied.
    public func applying(_ overrides: StyleOverrides?) -> TitleStyle {
        guard let overrides else { return self }
        var style = self
        if let position = overrides.position { style.position = position }
        if let ratio = overrides.fontSizeRatio { style.fontSizeRatio = ratio }
        if let alignment = overrides.alignment { style.alignment = alignment }
        return style
    }
}

/// Lays out titles with Core Text into bitmaps (§6.3 step 2) and caches them.
///
/// The cache holds one entry per title ID. An entry is reused only while the
/// text, the words, the effective style and the render size are all
/// unchanged; any change replaces it. Safe to call from any thread.
public final class TitleRenderer: Sendable {
    private struct Entry {
        var text: String
        var words: [TimedWord]?
        var style: TitleStyle
        var renderSize: CGSize
        /// `nil` results are cached too.
        var images: [ImageKey: RenderedTitle?]
    }

    /// One frame's variant of a title: how many characters show (typewriter)
    /// and which word is highlighted, if any.
    private struct ImageKey: Hashable {
        var visible: Int
        var highlight: Int?
    }

    /// Partial (typewriter) renders kept per title, besides the full ones.
    private static let partialLimit = 8

    private let cache = Mutex<[UUID: Entry]>([:])

    public init() {}

    /// The bitmap for `title` drawn in `style` (overrides are applied here),
    /// cached. `nil` when there is nothing to draw.
    ///
    /// - Parameters:
    ///   - visibleCharacters: Characters to draw, for the typewriter
    ///     transition; `nil` draws all. Layout is always that of the full text,
    ///     so characters appear in place and the background box does not grow.
    ///   - highlightedWord: Index into `title.words` of the word to draw in the
    ///     style's highlight colour. Ignored when the style has no highlight or
    ///     the words no longer match the text. Only the colour changes.
    public func render(_ title: Title, style: TitleStyle, renderSize: CGSize,
                       visibleCharacters: Int? = nil,
                       highlightedWord: Int? = nil) -> RenderedTitle? {
        let effective = style.applying(title.styleOverrides)
        let count = title.text.count
        let visible = min(max(visibleCharacters ?? count, 0), count)
        var highlight: (range: Range<String.Index>, color: RGBA)?
        if let color = effective.highlight?.color, let index = highlightedWord,
           let words = title.words, let ranges = WordHighlight.ranges(of: words, in: title.text),
           ranges.indices.contains(index) {
            highlight = (ranges[index], color)
        }
        let key = ImageKey(visible: visible, highlight: highlight == nil ? nil : highlightedWord)

        let cached: RenderedTitle?? = cache.withLock { cache in
            guard let entry = cache[title.id], entry.text == title.text,
                  entry.words == title.words, entry.style == effective,
                  entry.renderSize == renderSize else { return nil }
            return entry.images[key]
        }
        if let cached { return cached }

        let rendered = Self.draw(text: title.text, style: effective, renderSize: renderSize,
                                 visibleCharacters: visible, highlight: highlight)
        cache.withLock { cache in
            if var entry = cache[title.id], entry.text == title.text,
               entry.words == title.words, entry.style == effective,
               entry.renderSize == renderSize {
                if visible != count, entry.images.count > Self.partialLimit {
                    entry.images = entry.images.filter { $0.key.visible == count }
                }
                entry.images[key] = rendered
                cache[title.id] = entry
            } else {
                cache[title.id] = Entry(text: title.text, words: title.words, style: effective,
                                        renderSize: renderSize, images: [key: rendered])
            }
        }
        return rendered
    }

    /// Drops cached bitmaps for titles not in `ids`.
    public func retainOnly(_ ids: Set<UUID>) {
        cache.withLock { cache in cache = cache.filter { ids.contains($0.key) } }
    }

    // MARK: Drawing

    /// Lays out and draws `text` in `style` for a frame of `renderSize`.
    /// Uncached. `nil` for empty text or a degenerate size.
    ///
    /// Font size is `style.fontSizeRatio` of the render height; text wraps at
    /// `style.maxWidthRatio` of the render width, less background padding.
    /// Shadow offsets are y-up: a negative `offsetYRatio` falls below the text.
    /// `highlight` recolours one range of the text's fill; the layout is the same.
    public static func draw(text: String, style: TitleStyle, renderSize: CGSize,
                            visibleCharacters: Int? = nil,
                            highlight: (range: Range<String.Index>, color: RGBA)? = nil)
        -> RenderedTitle? {
        let fontSize = style.fontSizeRatio * renderSize.height
        guard !text.isEmpty, fontSize >= 1, renderSize.width >= 1 else { return nil }

        let font = makeFont(name: style.fontName, weight: style.weight, size: fontSize)
        let visible = visibleCharacters ?? text.count
        let string = attributedString(text, style: style, font: font, visibleCharacters: visible,
                                      pass: .fill, highlight: highlight)
        let framesetter = CTFramesetterCreateWithAttributedString(string)

        let padding = style.background.map { max($0.paddingRatio, 0) * fontSize } ?? 0
        let wrapWidth = max(style.maxWidthRatio * renderSize.width - 2 * padding, fontSize)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: wrapWidth, height: .greatestFiniteMagnitude), nil)
        // One spare point stops Core Text re-wrapping the last word when the
        // frame is exactly the suggested width.
        let textSize = CGSize(width: min(suggested.width.rounded(.up) + 1, wrapWidth + 1),
                              height: suggested.height.rounded(.up))
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        let fitted = (textSize.width + 2 * padding).rounded(.up)
        let boxWidth = style.background?.widthRatio
            .map { (min(max($0, 0), 1) * renderSize.width).rounded() } ?? 0
        let content = CGSize(width: max(fitted, boxWidth),
                             height: (textSize.height + 2 * padding).rounded(.up))
        // Room a wide box leaves beside the text, before it by the alignment.
        let spare = content.width - fitted
        let lead: CGFloat = switch style.alignment {
        case .leading: 0
        case .center: (spare / 2).rounded()
        case .trailing: spare
        }
        let margin = Self.margin(for: style, fontSize: fontSize)
        let width = Int(content.width + 2 * margin)
        let height = Int(content.height + 2 * margin)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)

        let contentRect = CGRect(x: margin, y: margin, width: content.width,
                                 height: content.height)
        if let box = style.background {
            let radius = min(max(box.cornerRadiusRatio, 0) * fontSize,
                             contentRect.width / 2, contentRect.height / 2)
            context.addPath(CGPath(roundedRect: contentRect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.setFillColor(box.color.cgColor)
            context.fillPath()
        }

        if let shadow = style.shadow {
            context.setShadow(offset: CGSize(width: shadow.offsetXRatio * fontSize,
                                             height: shadow.offsetYRatio * fontSize),
                              blur: max(shadow.radiusRatio, 0) * fontSize,
                              color: shadow.color.cgColor)
        }
        // The frame spans the fitted width so alignment applies across the
        // text's lines; text sits inside the padding, moved across a wide box.
        let textRect = CGRect(x: margin + lead + padding, y: margin + padding,
                              width: fitted - 2 * padding,
                              height: content.height - 2 * padding)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             path, nil)
        if let stroke = style.stroke, stroke.widthRatio > 0 {
            // Outline first, fill on top, so the outline sits outside the
            // letters instead of eating into them. One layer, so the shadow
            // falls once behind both.
            let outline = attributedString(text, style: style, font: font,
                                           visibleCharacters: visible, pass: .outline)
            let outlineFrame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(outline),
                CFRange(location: 0, length: 0), path, nil)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setLineJoin(.round)
            CTFrameDraw(outlineFrame, context)
            CTFrameDraw(frame, context)
            context.endTransparencyLayer()
        } else {
            CTFrameDraw(frame, context)
        }

        guard let image = context.makeImage() else { return nil }
        return RenderedTitle(image: image, contentRect: contentRect)
    }

    /// Room around the content for shadow blur, shadow offset and stroke.
    private static func margin(for style: TitleStyle, fontSize: Double) -> CGFloat {
        var margin = 2.0
        if let shadow = style.shadow {
            margin += (max(shadow.radiusRatio, 0) * 2
                + max(abs(shadow.offsetXRatio), abs(shadow.offsetYRatio))) * fontSize
        }
        if let stroke = style.stroke {
            margin += max(stroke.widthRatio, 0) * fontSize
        }
        return margin.rounded(.up)
    }

    /// Which part of the text a drawing pass paints.
    private enum Pass {
        case fill
        /// The outline only, twice the stroke width so the half outside the
        /// letters is `stroke.widthRatio` of the font size.
        case outline
    }

    private static func attributedString(
        _ text: String, style: TitleStyle, font: CTFont, visibleCharacters: Int, pass: Pass,
        highlight: (range: Range<String.Index>, color: RGBA)? = nil
    ) -> CFAttributedString {
        var alignment: CTTextAlignment = switch style.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &lineBreak) { lineBreakBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment,
                                            valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode,
                                            valueSize: MemoryLayout<CTLineBreakMode>.size,
                                            value: lineBreakBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }

        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                style.textColor.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if pass == .outline, let stroke = style.stroke {
            // Positive width = stroke only; the value is a percentage of the font size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                stroke.widthRatio * 2 * 100
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                stroke.color.cgColor
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes)

        if pass == .fill, let highlight {
            string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                value: highlight.color.cgColor,
                                range: NSRange(highlight.range, in: text))
        }
        // After the highlight, so characters the typewriter hides stay hidden.
        if visibleCharacters < text.count {
            let hiddenStart = text.index(text.startIndex, offsetBy: max(visibleCharacters, 0))
            let range = NSRange(hiddenStart..<text.endIndex, in: text)
            let clear = CGColor(gray: 0, alpha: 0)
            string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                value: clear, range: range)
            string.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String),
                                value: clear, range: range)
        }
        return string as CFAttributedString
    }

    /// The font `name` (family or PostScript name) at `weight`. Unknown names
    /// fall back to the system font.
    static func makeFont(name: String, weight: FontWeight, size: Double) -> CTFont {
        let base: CTFont
        if name.isEmpty || name == "System" {
            base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        } else {
            base = CTFontCreateWithName(name as CFString, size, nil)
        }
        let family = CTFontCopyFamilyName(base)
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: weight.coreTextWeight],
        ] as CFDictionary)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) else {
            return base
        }
        return CTFontCreateWithFontDescriptor(matched, size, nil)
    }
}

extension FontWeight {
    /// Core Text weight trait, -1...1.
    var coreTextWeight: Double {
        switch self {
        case .ultraLight: -0.8
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }
}

extension RGBA {
    /// sRGB `CGColor`.
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
