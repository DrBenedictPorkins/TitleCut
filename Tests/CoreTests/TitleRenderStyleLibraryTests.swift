import CoreText
import Foundation
import Testing
@testable import TitleCutCore

struct TitleRenderStyleLibraryTests {
    /// A library over a fresh temporary file and defaults suite.
    private func makeLibrary() -> StyleLibrary {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-styles-\(UUID().uuidString)", isDirectory: true)
        let suite = "titlecut-tests-\(UUID().uuidString)"
        return StyleLibrary(fileURL: folder.appendingPathComponent("styles.json"),
                            defaults: UserDefaults(suiteName: suite)!)
    }

    private var custom: TitleStyle {
        var style = StyleLibrary.caption
        style.id = Fixture.id(500)
        style.name = "Mine"
        return style
    }

    @Test func builtInsAreTheShippedFourteen() {
        #expect(StyleLibrary.builtIns.map(\.name)
                == ["Dark Box", "Bold Shadow", "Subtitle", "Serif", "Light", "Yellow Tag",
                    "Meme", "Meme Inverted", "Neon", "Hollow", "Paper", "Red Banner", "Marker",
                    "Highlight"])
        #expect(Set(StyleLibrary.builtIns.map(\.id)).count == 14)
    }

    @Test func builtInFontsAreInstalled() {
        for style in StyleLibrary.builtIns {
            let font = TitleRenderer.makeFont(name: style.fontName, weight: style.weight, size: 20)
            #expect(CTFontCopyFamilyName(font) as String == style.fontName, "\(style.name)")
        }
    }

    @Test func everyBuiltInRendersAndThumbnails() throws {
        for style in StyleLibrary.builtIns {
            #expect(TitleRenderer.draw(text: style.name, style: style,
                                       renderSize: CGSize(width: 1920, height: 1080)) != nil,
                    "\(style.name)")
            let thumbnail = try #require(StyleLibrary.thumbnail(
                for: style, size: CGSize(width: 320, height: 180)))
            #expect(thumbnail.width == 320 && thumbnail.height == 180)
        }
    }

    @Test func thumbnailShowsTheStyleLargeAndCentred() throws {
        let plain = try #require(StyleLibrary.thumbnail(
            for: StyleLibrary.callout, text: "Title", size: CGSize(width: 320, height: 180)))
        let pixels = RenderFixture.pixels(of: plain)
        // Callout is a yellow box at the top of the frame; the thumbnail centres it
        // and scales it to fill most of the tile.
        var yellow = 0, sumX = 0, sumY = 0
        for y in 0..<180 {
            for x in 0..<320 {
                let c = pixels.rgb(x: x, y: y)
                if c.r > 200 && c.g > 180 && c.b < 80 {
                    yellow += 1
                    sumX += x
                    sumY += y
                }
            }
        }
        #expect(yellow > 320 * 180 / 4, "\(yellow)")
        #expect(abs(sumX / max(yellow, 1) - 160) < 6)
        #expect(abs(sumY / max(yellow, 1) - 90) < 6)
    }

    @Test func missingFileYieldsBuiltIns() throws {
        let library = makeLibrary()
        #expect(try library.styles() == StyleLibrary.builtIns)
        #expect(try library.savedStyles().isEmpty)
    }

    @Test func saveAddsAndReplaces() throws {
        let library = makeLibrary()
        try library.save(custom)
        #expect(try library.styles() == StyleLibrary.builtIns + [custom])

        var renamed = custom
        renamed.name = "Renamed"
        try library.save(renamed)
        #expect(try library.styles().last == renamed)
        #expect(try library.savedStyles() == [renamed])
    }

    @Test func editedBuiltInReplacesItInPlace() throws {
        let library = makeLibrary()
        var edited = StyleLibrary.lowerThird
        edited.fontSizeRatio = 0.08
        try library.save(edited)
        let styles = try library.styles()
        #expect(styles.count == StyleLibrary.builtIns.count)
        #expect(styles.first == edited)

        // Saving it back to its shipped form drops the saved copy.
        try library.save(StyleLibrary.lowerThird)
        #expect(try library.savedStyles().isEmpty)
        #expect(try library.styles() == StyleLibrary.builtIns)
    }

    @Test func removeDeletesSavedStyle() throws {
        let library = makeLibrary()
        try library.save(custom)
        try library.remove(id: custom.id)
        #expect(try library.styles() == StyleLibrary.builtIns)
        try library.remove(id: Fixture.id(404))
    }

    @Test func fileRoundTripsThroughDisk() throws {
        let library = makeLibrary()
        try library.save(custom)
        let reopened = StyleLibrary(fileURL: library.fileURL, defaults: library.defaults)
        #expect(try reopened.savedStyles() == [custom])
    }

    @Test func newerFormatIsRefused() throws {
        let library = makeLibrary()
        try FileManager.default.createDirectory(at: library.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"formatVersion": 2, "styles": []}"#.utf8).write(to: library.fileURL)
        #expect(throws: StyleLibrary.ReadError.newerFormat(found: 2)) {
            try library.styles()
        }
    }

    @Test func defaultStyleFallsBackToLowerThird() throws {
        let library = makeLibrary()
        #expect(library.defaultStyleID == nil)
        #expect(try library.defaultStyle() == StyleLibrary.lowerThird)

        library.setDefaultStyleID(StyleLibrary.calloutID)
        #expect(library.defaultStyleID == StyleLibrary.calloutID)
        #expect(try library.defaultStyle() == StyleLibrary.callout)

        // A default that no longer exists falls back.
        try library.save(custom)
        library.setDefaultStyleID(custom.id)
        #expect(try library.defaultStyle() == custom)
        try library.remove(id: custom.id)
        #expect(try library.defaultStyle() == StyleLibrary.lowerThird)

        library.setDefaultStyleID(nil)
        #expect(library.defaultStyleID == nil)
    }

    @Test func renameSavesTheNewName() throws {
        let library = makeLibrary()
        try library.save(custom)
        try library.rename(id: custom.id, to: "Ours")
        #expect(try library.savedStyles().map(\.name) == ["Ours"])

        // Renaming a built-in saves a changed copy; removing it reverts.
        try library.rename(id: StyleLibrary.memeID, to: "Loud")
        let renamed = try #require(try library.styles().first { $0.id == StyleLibrary.memeID })
        #expect(renamed.name == "Loud")
        #expect(StyleLibrary.isChangedBuiltIn(renamed))
        try library.remove(id: StyleLibrary.memeID)
        #expect(try library.styles().first { $0.id == StyleLibrary.memeID } == StyleLibrary.meme)
        #expect(!StyleLibrary.isChangedBuiltIn(StyleLibrary.meme))
        #expect(!StyleLibrary.isBuiltIn(custom.id))

        try library.rename(id: Fixture.id(404), to: "Nobody")
        #expect(try library.savedStyles().count == 1)
    }

    @Test func styleWithoutBasedOnDecodes() throws {
        var encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(custom)) as! [String: Any]
        encoded["basedOn"] = nil
        let style = try JSONDecoder().decode(
            TitleStyle.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(style == custom)
        #expect(style.basedOn == nil)
    }

    @Test func overridesApply() {
        let style = StyleLibrary.lowerThird.applying(
            StyleOverrides(position: .custom(x: 0.1, y: 0.2), fontSizeRatio: 0.2))
        #expect(style.position == .custom(x: 0.1, y: 0.2))
        #expect(style.fontSizeRatio == 0.2)
        #expect(style.weight == StyleLibrary.lowerThird.weight)
        #expect(StyleLibrary.lowerThird.applying(nil) == StyleLibrary.lowerThird)
    }
}
