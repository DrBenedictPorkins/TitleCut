import CoreGraphics
import Foundation

/// App-wide title style presets (§5.2).
///
/// Built-in styles ship in code. Saved styles live in
/// `~/Library/Application Support/TitleCut/styles.json`; a saved style with a
/// built-in's ID replaces that built-in. The default style for new titles is
/// an ID kept in `UserDefaults` under `defaultStyleKey`.
///
/// Stateless: every call reads or writes the file. Projects never read the
/// library when rendering; applying a style copies it into `Project.styles`.
public struct StyleLibrary: @unchecked Sendable {
    /// `UserDefaults` key holding the default style's UUID string.
    public static let defaultStyleKey = "defaultTitleStyleID"

    /// Format of `styles.json`.
    struct File: Codable, Equatable {
        static let currentFormatVersion = 1
        var formatVersion = File.currentFormatVersion
        var styles: [TitleStyle]
    }

    public enum ReadError: LocalizedError, Equatable {
        case newerFormat(found: Int)

        public var errorDescription: String? {
            switch self {
            case .newerFormat(let found):
                "The style library was saved by a newer version of TitleCut (format \(found))."
            }
        }
    }

    public let fileURL: URL
    /// `UserDefaults` is documented as thread-safe.
    public let defaults: UserDefaults

    public init(fileURL: URL = StyleLibrary.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    /// `~/Library/Application Support/TitleCut/styles.json`.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("TitleCut", isDirectory: true)
            .appendingPathComponent("styles.json")
    }

    // MARK: Reading and writing

    /// Built-ins in their fixed order (each replaced by a saved copy with the
    /// same ID, if any), then saved styles in file order. A missing file
    /// yields the built-ins.
    public func styles() throws -> [TitleStyle] {
        let saved = try savedStyles()
        var merged = Self.builtIns.map { builtIn in
            saved.first { $0.id == builtIn.id } ?? builtIn
        }
        let builtInIDs = Set(Self.builtIns.map(\.id))
        merged += saved.filter { !builtInIDs.contains($0.id) }
        return merged
    }

    /// Styles in the file only. Empty if the file does not exist.
    public func savedStyles() throws -> [TitleStyle] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        struct Header: Decodable { var formatVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.formatVersion <= File.currentFormatVersion else {
            throw ReadError.newerFormat(found: header.formatVersion)
        }
        return try JSONDecoder().decode(File.self, from: data).styles
    }

    /// Adds `style` to the library, or replaces the style with its ID. Saving
    /// a style identical to its built-in removes the saved copy instead.
    public func save(_ style: TitleStyle) throws {
        var saved = try savedStyles()
        let isUnchangedBuiltIn = Self.builtIns.contains(style)
        if let index = saved.firstIndex(where: { $0.id == style.id }) {
            if isUnchangedBuiltIn { saved.remove(at: index) } else { saved[index] = style }
        } else if !isUnchangedBuiltIn {
            saved.append(style)
        }
        try write(saved)
    }

    /// Removes the saved style `id`. A built-in reverts to its shipped form.
    public func remove(id: UUID) throws {
        var saved = try savedStyles()
        guard saved.contains(where: { $0.id == id }) else { return }
        saved.removeAll { $0.id == id }
        try write(saved)
    }

    /// Renames style `id`. Renaming a built-in saves a changed copy of it.
    /// Does nothing if no style has that ID.
    public func rename(id: UUID, to name: String) throws {
        guard var style = try styles().first(where: { $0.id == id }) else { return }
        style.name = name
        try save(style)
    }

    /// Whether `id` is a shipped style, which can be reverted but not deleted.
    public static func isBuiltIn(_ id: UUID) -> Bool {
        builtIns.contains { $0.id == id }
    }

    /// Whether `style` is a built-in with saved changes.
    public static func isChangedBuiltIn(_ style: TitleStyle) -> Bool {
        isBuiltIn(style.id) && !builtIns.contains(style)
    }

    private func write(_ styles: [TitleStyle]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(styles: styles))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Default style for new titles

    /// The ID chosen as the default, if one has been set.
    public var defaultStyleID: UUID? {
        defaults.string(forKey: Self.defaultStyleKey).flatMap(UUID.init(uuidString:))
    }

    /// Sets the default style for new titles; `nil` reverts to Lower Third.
    public func setDefaultStyleID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.defaultStyleKey)
        } else {
            defaults.removeObject(forKey: Self.defaultStyleKey)
        }
    }

    /// The default style, falling back to Lower Third when none is set or the
    /// chosen style no longer exists.
    public func defaultStyle() throws -> TitleStyle {
        let all = try styles()
        if let id = defaultStyleID, let style = all.first(where: { $0.id == id }) {
            return style
        }
        return all.first { $0.id == Self.lowerThirdID } ?? Self.lowerThird
    }

    // MARK: Thumbnails

    /// A picker thumbnail: `text` (the style name if `nil`) drawn in `style`,
    /// scaled up to fill most of a mid-grey frame of `size` pixels and centred.
    /// The style's position is ignored; titles are placed per title.
    public static func thumbnail(for style: TitleStyle, text: String? = nil,
                                 size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGSize(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))

        let sample = text ?? style.name
        // Measure at the frame's size, then draw again at the scale that fills
        // 90 % of the width or 78 % of the height. Font size and wrap width both
        // follow the render size, so the layout only scales.
        guard let measured = TitleRenderer.draw(text: sample, style: style, renderSize: canvas)
        else { return context.makeImage() }
        let box = measured.contentRect.size
        let scale = min(canvas.width * 0.9 / box.width, canvas.height * 0.78 / box.height)
        let rendered = TitleRenderer.draw(
            text: sample, style: style,
            renderSize: CGSize(width: canvas.width * scale, height: canvas.height * scale))
            ?? measured
        let content = rendered.contentRect
        // Bottom-left origin: centre the content box, then extend to the whole bitmap.
        let originX = ((canvas.width - content.width) / 2 - content.minX).rounded()
        let originY = ((canvas.height - content.height) / 2 - content.minY).rounded()
        context.draw(rendered.image, in: CGRect(
            x: originX, y: originY, width: CGFloat(rendered.image.width),
            height: CGFloat(rendered.image.height)))
        return context.makeImage()
    }

    // MARK: Built-in styles

    public static let lowerThirdID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000001")!
    public static let centeredBoldID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000002")!
    public static let captionID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000003")!
    public static let chapterCardID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000004")!
    public static let minimalID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000005")!
    public static let calloutID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000006")!
    public static let memeID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000007")!
    public static let memeInvertedID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000008")!
    public static let neonID = UUID(uuidString: "7C1E0001-0000-4000-8000-000000000009")!
    public static let hollowID = UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000A")!
    public static let paperID = UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000B")!
    public static let redBannerID = UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000C")!
    public static let markerID = UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000D")!
    public static let highlightID = UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000E")!

    private static let white = RGBA(red: 1, green: 1, blue: 1)
    private static let softShadow = Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                           radiusRatio: 0.08, offsetXRatio: 0,
                                           offsetYRatio: -0.04)

    // Names describe the look. The Swift names and IDs predate them and stay,
    // because projects and the default-style setting refer to the IDs.

    public static let lowerThird = TitleStyle(
        id: lowerThirdID, name: "Dark Box", fontName: "Helvetica Neue",
        fontSizeRatio: 0.055, weight: .semibold, textColor: white,
        background: BackgroundBox(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                  paddingRatio: 0.4, cornerRadiusRatio: 0.15),
        alignment: .leading, position: .lowerThird, maxWidthRatio: 0.6)

    public static let centeredBold = TitleStyle(
        id: centeredBoldID, name: "Bold Shadow", fontName: "Helvetica Neue",
        fontSizeRatio: 0.09, weight: .bold, textColor: white, shadow: softShadow,
        alignment: .center, position: .center, maxWidthRatio: 0.8)

    /// Film subtitle: yellow with a thin black outline.
    public static let caption = TitleStyle(
        id: captionID, name: "Subtitle", fontName: "Helvetica Neue",
        fontSizeRatio: 0.05, weight: .semibold,
        textColor: RGBA(red: 1, green: 0.9, blue: 0.2),
        stroke: Stroke(color: RGBA(red: 0, green: 0, blue: 0), widthRatio: 0.025),
        alignment: .center, position: .bottom, maxWidthRatio: 0.8)

    public static let chapterCard = TitleStyle(
        id: chapterCardID, name: "Serif", fontName: "Georgia",
        fontSizeRatio: 0.1, weight: .bold, textColor: white, shadow: softShadow,
        stroke: Stroke(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.8), widthRatio: 0.015),
        alignment: .center, position: .center, maxWidthRatio: 0.7)

    public static let minimal = TitleStyle(
        id: minimalID, name: "Light", fontName: "Helvetica Neue",
        fontSizeRatio: 0.045, weight: .light, textColor: white,
        shadow: Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.4),
                       radiusRatio: 0.05, offsetXRatio: 0, offsetYRatio: -0.02),
        alignment: .leading, position: .lowerThird, maxWidthRatio: 0.6)

    public static let callout = TitleStyle(
        id: calloutID, name: "Yellow Tag", fontName: "Avenir Next",
        fontSizeRatio: 0.05, weight: .bold, textColor: RGBA(red: 0.08, green: 0.08, blue: 0.08),
        background: BackgroundBox(color: RGBA(red: 1, green: 0.84, blue: 0.1),
                                  paddingRatio: 0.35, cornerRadiusRatio: 0.3),
        alignment: .center, position: .top, maxWidthRatio: 0.6)

    private static let black = RGBA(red: 0, green: 0, blue: 0)

    /// Impact, white with a heavy black outline: the classic meme caption.
    public static let meme = TitleStyle(
        id: memeID, name: "Meme", fontName: "Impact",
        fontSizeRatio: 0.09, weight: .regular, textColor: white,
        stroke: Stroke(color: black, widthRatio: 0.045),
        alignment: .center, position: .top, maxWidthRatio: 0.9)

    /// `meme` with the colours swapped: black letters, white outline.
    public static let memeInverted = TitleStyle(
        id: memeInvertedID, name: "Meme Inverted", fontName: "Impact",
        fontSizeRatio: 0.09, weight: .regular, textColor: black,
        stroke: Stroke(color: white, widthRatio: 0.045),
        alignment: .center, position: .bottom, maxWidthRatio: 0.9)

    /// Cyan letters with a cyan glow.
    public static let neon = TitleStyle(
        id: neonID, name: "Neon", fontName: "Avenir Next",
        fontSizeRatio: 0.08, weight: .heavy, textColor: RGBA(red: 0.75, green: 1, blue: 1),
        shadow: Shadow(color: RGBA(red: 0, green: 0.9, blue: 1, alpha: 0.95),
                       radiusRatio: 0.2, offsetXRatio: 0, offsetYRatio: 0),
        alignment: .center, position: .center, maxWidthRatio: 0.8)

    /// Outline only: clear letters with a white outline.
    public static let hollow = TitleStyle(
        id: hollowID, name: "Hollow", fontName: "Futura",
        fontSizeRatio: 0.1, weight: .bold, textColor: RGBA(red: 1, green: 1, blue: 1, alpha: 0),
        stroke: Stroke(color: white, widthRatio: 0.03),
        alignment: .center, position: .center, maxWidthRatio: 0.85)

    /// Typewriter text on a white card.
    public static let paper = TitleStyle(
        id: paperID, name: "Paper", fontName: "American Typewriter",
        fontSizeRatio: 0.05, weight: .regular, textColor: RGBA(red: 0.1, green: 0.1, blue: 0.1),
        background: BackgroundBox(color: RGBA(red: 0.98, green: 0.97, blue: 0.94),
                                  paddingRatio: 0.45, cornerRadiusRatio: 0.05),
        alignment: .leading, position: .lowerThird, maxWidthRatio: 0.6)

    /// White Futura on a square red banner.
    public static let redBanner = TitleStyle(
        id: redBannerID, name: "Red Banner", fontName: "Futura",
        fontSizeRatio: 0.055, weight: .bold, textColor: white,
        background: BackgroundBox(color: RGBA(red: 0.86, green: 0.12, blue: 0.15),
                                  paddingRatio: 0.35, cornerRadiusRatio: 0),
        alignment: .leading, position: .lowerThird, maxWidthRatio: 0.7)

    /// Felt-tip marker lettering with a hard drop shadow.
    public static let marker = TitleStyle(
        id: markerID, name: "Marker", fontName: "Marker Felt",
        fontSizeRatio: 0.08, weight: .regular, textColor: white,
        shadow: Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.85),
                       radiusRatio: 0, offsetXRatio: 0.04, offsetYRatio: -0.04),
        alignment: .center, position: .center, maxWidthRatio: 0.8)

    /// Bold white captions with a black outline; the spoken word turns yellow.
    public static let highlight = TitleStyle(
        id: highlightID, name: "Highlight", fontName: "Avenir Next",
        fontSizeRatio: 0.065, weight: .heavy, textColor: white,
        stroke: Stroke(color: black, widthRatio: 0.04),
        alignment: .center, position: .bottom, maxWidthRatio: 0.8,
        highlight: TitleHighlight(color: RGBA(red: 1, green: 0.84, blue: 0.1)))

    /// Shipped presets, in picker order.
    public static let builtIns: [TitleStyle] = [
        lowerThird, centeredBold, caption, chapterCard, minimal, callout, meme, memeInverted,
        neon, hollow, paper, redBanner, marker, highlight,
    ]
}
