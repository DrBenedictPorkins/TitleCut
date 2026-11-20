import Foundation

/// A title look. Sizes are ratios so a style is resolution-independent.
public struct TitleStyle: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// PostScript or family name.
    public var fontName: String
    /// Fraction of output height.
    public var fontSizeRatio: Double
    public var weight: FontWeight
    public var textColor: RGBA
    public var background: BackgroundBox?
    public var shadow: Shadow?
    public var stroke: Stroke?
    public var alignment: TextAlignment
    public var position: NormalizedPosition
    /// Wrap width as a fraction of output width.
    public var maxWidthRatio: Double
    /// Colour of the word being spoken, for titles that carry word times.
    /// Absent from files written before it existed.
    public var highlight: TitleHighlight?
    /// For a title's customised copy of a library style: that style's ID, so
    /// the copy can be written back over it. `nil` for library styles and
    /// files written before it existed.
    public var basedOn: UUID?

    public init(id: UUID, name: String, fontName: String, fontSizeRatio: Double,
                weight: FontWeight, textColor: RGBA, background: BackgroundBox? = nil,
                shadow: Shadow? = nil, stroke: Stroke? = nil, alignment: TextAlignment,
                position: NormalizedPosition, maxWidthRatio: Double,
                highlight: TitleHighlight? = nil, basedOn: UUID? = nil) {
        self.id = id
        self.name = name
        self.fontName = fontName
        self.fontSizeRatio = fontSizeRatio
        self.weight = weight
        self.textColor = textColor
        self.background = background
        self.shadow = shadow
        self.stroke = stroke
        self.alignment = alignment
        self.position = position
        self.maxWidthRatio = maxWidthRatio
        self.highlight = highlight
        self.basedOn = basedOn
    }
}

/// The spoken-word highlight: the word changes to `color`; nothing else changes.
public struct TitleHighlight: Codable, Sendable, Equatable {
    public var color: RGBA

    public init(color: RGBA) {
        self.color = color
    }
}

public enum FontWeight: String, Codable, Sendable, Equatable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}

/// Colour with components 0...1 in sRGB.
public struct RGBA: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Box drawn behind the text. Lengths are fractions of the font size.
public struct BackgroundBox: Codable, Sendable, Equatable {
    public var color: RGBA
    public var paddingRatio: Double
    public var cornerRadiusRatio: Double
    /// The box's width as a fraction of the frame's; `nil` fits the text.
    /// Never narrower than the text. The text lines up inside it by the
    /// style's alignment.
    public var widthRatio: Double?

    public init(color: RGBA, paddingRatio: Double, cornerRadiusRatio: Double,
                widthRatio: Double? = nil) {
        self.color = color
        self.paddingRatio = paddingRatio
        self.cornerRadiusRatio = cornerRadiusRatio
        self.widthRatio = widthRatio
    }
}

/// Text shadow. Lengths are fractions of the font size.
public struct Shadow: Codable, Sendable, Equatable {
    public var color: RGBA
    public var radiusRatio: Double
    public var offsetXRatio: Double
    public var offsetYRatio: Double

    public init(color: RGBA, radiusRatio: Double, offsetXRatio: Double, offsetYRatio: Double) {
        self.color = color
        self.radiusRatio = radiusRatio
        self.offsetXRatio = offsetXRatio
        self.offsetYRatio = offsetYRatio
    }
}

/// Text outline, drawn outside the letters. Width is a fraction of the font size.
public struct Stroke: Codable, Sendable, Equatable {
    public var color: RGBA
    public var widthRatio: Double

    public init(color: RGBA, widthRatio: Double) {
        self.color = color
        self.widthRatio = widthRatio
    }
}

public enum TextAlignment: String, Codable, Sendable, Equatable {
    case leading, center, trailing
}

/// Where the title's text block sits. Presets, or a custom centre point
/// normalised 0...1 in output space with the origin at top-left.
public enum NormalizedPosition: Codable, Sendable, Equatable {
    case lowerThird
    case center
    case top
    case bottom
    case custom(x: Double, y: Double)
}
