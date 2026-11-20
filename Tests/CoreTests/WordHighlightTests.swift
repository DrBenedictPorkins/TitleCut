import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// The spoken-word highlight: model fields, word matching, timing and drawing.
struct WordHighlightTests {
    private func word(_ text: String, _ start: Tick, _ end: Tick) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    private let yellow = RGBA(red: 1, green: 0.84, blue: 0.1)

    // MARK: Codable

    @Test func newFieldsRoundTripAndAreOmittedWhenAbsent() throws {
        var project = TitleCommandFixture.project
        project.titles[0].words = [word("T10", 0, 120)]
        project.styles[0].highlight = TitleHighlight(color: yellow)
        let json = String(decoding: try ProjectFile.encode(project), as: UTF8.self)
        #expect(json.contains("\"words\""))
        #expect(json.contains("\"highlight\""))
        #expect(try ProjectFile.decode(Data(json.utf8)) == project)

        let plain = String(decoding: try ProjectFile.encode(TitleCommandFixture.project),
                           as: UTF8.self)
        #expect(!plain.contains("\"words\"") && !plain.contains("\"highlight\""))
    }

    @Test func oldJSONWithoutTheFieldsLoads() throws {
        // Written before words and highlight existed: no such keys at all.
        let project = TitleCommandFixture.project
        let data = try ProjectFile.encode(project)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var titles = try #require(object["titles"] as? [[String: Any]])
        titles = titles.map { $0.filter { $0.key != "words" && $0.key != "origin" } }
        object["titles"] = titles
        let old = try JSONSerialization.data(withJSONObject: object)
        let loaded = try ProjectFile.decode(old)
        #expect(loaded == project)
        #expect(loaded.titles.allSatisfy { $0.words == nil })
        #expect(loaded.styles.allSatisfy { $0.highlight == nil })
    }

    // MARK: Matching words to the text

    @Test func wordsMatchTheTextInOrderWithPunctuation() throws {
        let text = "Well, hello\nworld!"
        let ranges = try #require(WordHighlight.ranges(
            of: [word("Well,", 0, 1), word("hello", 1, 2), word("world!", 2, 3)], in: text))
        #expect(ranges.map { String(text[$0]) } == ["Well,", "hello", "world!"])
    }

    @Test func editedTextNoLongerMatches() {
        let words = [word("Hello", 0, 1), word("world.", 1, 2)]
        #expect(WordHighlight.ranges(of: words, in: "Hello world.") != nil)
        #expect(WordHighlight.ranges(of: words, in: " Hello  world. ") != nil)
        #expect(WordHighlight.ranges(of: words, in: "Hello there world.") == nil)
        #expect(WordHighlight.ranges(of: words, in: "Hello world") == nil)
        #expect(WordHighlight.ranges(of: words, in: "Hello world. Again") == nil)
        #expect(WordHighlight.ranges(of: words, in: "Hi world.") == nil)
        #expect(WordHighlight.ranges(of: [], in: "Hello") == nil)
    }

    // MARK: Which word

    @Test func highlightedIndexOverTime() {
        let words = [word("a", 50, 100), word("b", 200, 300)]
        #expect(WordHighlight.index(at: 0, in: words) == nil)
        #expect(WordHighlight.index(at: 49.9, in: words) == nil)
        #expect(WordHighlight.index(at: 50, in: words) == 0)
        #expect(WordHighlight.index(at: 99, in: words) == 0)
        // Between words the last spoken one stays lit.
        #expect(WordHighlight.index(at: 150, in: words) == 0)
        #expect(WordHighlight.index(at: 200, in: words) == 1)
        #expect(WordHighlight.index(at: 1000, in: words) == 1)
    }

    @Test func appearanceCarriesTheIndexFromTheTitleStart() {
        let title = Title(id: Fixture.id(1), text: "a b",
                          anchor: TitleAnchor(segmentID: Fixture.id(2), offset: 0),
                          duration: 600, styleID: Fixture.id(800),
                          words: [word("a", 0, 100), word("b", 200, 300)])
        let range = TickRange(start: 1000, duration: 600)
        #expect(TransitionEvaluator.appearance(of: title, outputRange: range, at: Tick(1100))?
            .highlightedWord == 0)
        #expect(TransitionEvaluator.appearance(of: title, outputRange: range, at: Tick(1250))?
            .highlightedWord == 1)
        var plain = title
        plain.words = nil
        #expect(TransitionEvaluator.appearance(of: plain, outputRange: range, at: Tick(1250))?
            .highlightedWord == nil)
    }

    // MARK: Drawing

    private let size = CGSize(width: 800, height: 400)

    private var style: TitleStyle {
        TitleStyle(id: Fixture.id(800), name: "HL", fontName: "Helvetica Neue",
                   fontSizeRatio: 0.15, weight: .bold, textColor: RGBA(red: 1, green: 1, blue: 1),
                   alignment: .center, position: .center, maxWidthRatio: 0.9,
                   highlight: TitleHighlight(color: RGBA(red: 1, green: 0.84, blue: 0)))
    }

    private var title: Title {
        Title(id: Fixture.id(1), text: "AAA BBB",
              anchor: TitleAnchor(segmentID: Fixture.id(2), offset: 0), duration: 600,
              styleID: Fixture.id(800), words: [word("AAA", 0, 100), word("BBB", 200, 300)])
    }

    /// Yellow pixels and their mean x.
    private func yellowPixels(_ rendered: RenderedTitle) -> (count: Int, meanX: Double) {
        let pixels = RenderFixture.pixels(of: rendered.image)
        var count = 0, sumX = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let c = pixels.rgb(x: x, y: y)
                if c.r > 200, c.g > 150, c.g < 240, c.b < 60 {
                    count += 1
                    sumX += x
                }
            }
        }
        return (count, count > 0 ? Double(sumX) / Double(count) : 0)
    }

    @Test func spokenWordIsDrawnInTheHighlightColourWithTheSameLayout() throws {
        let renderer = TitleRenderer()
        let none = try #require(renderer.render(title, style: style, renderSize: size))
        let first = try #require(renderer.render(title, style: style, renderSize: size,
                                                 highlightedWord: 0))
        let second = try #require(renderer.render(title, style: style, renderSize: size,
                                                  highlightedWord: 1))
        for image in [first, second] {
            #expect(image.contentRect == none.contentRect)
            #expect(image.image.width == none.image.width
                    && image.image.height == none.image.height)
        }
        #expect(yellowPixels(none).count == 0)
        let a = yellowPixels(first), b = yellowPixels(second)
        #expect(a.count > 100 && b.count > 100)
        #expect(a.meanX < Double(none.image.width) / 2)
        #expect(b.meanX > Double(none.image.width) / 2)
        // The frame for a word is cached and reused.
        #expect(renderer.render(title, style: style, renderSize: size, highlightedWord: 0)?
            .image === first.image)
    }

    @Test func noHighlightWithoutAStyleColourOrAfterAnEdit() throws {
        let renderer = TitleRenderer()
        var plainStyle = style
        plainStyle.highlight = nil
        let plain = try #require(renderer.render(title, style: plainStyle, renderSize: size,
                                                 highlightedWord: 0))
        #expect(yellowPixels(plain).count == 0)

        var edited = title
        edited.text = "AAA CCC"
        let mismatched = try #require(renderer.render(edited, style: style, renderSize: size,
                                                      highlightedWord: 0))
        #expect(yellowPixels(mismatched).count == 0)
    }

    @Test func typewriterHidesAHighlightedWordNotYetTyped() throws {
        let renderer = TitleRenderer()
        let typed = try #require(renderer.render(title, style: style, renderSize: size,
                                                 visibleCharacters: 3, highlightedWord: 1))
        #expect(yellowPixels(typed).count == 0)
        let shown = try #require(renderer.render(title, style: style, renderSize: size,
                                                 visibleCharacters: 3, highlightedWord: 0))
        #expect(yellowPixels(shown).count > 100)
    }

    /// Mean x of yellow pixels in a composited frame, rendered like the compositor.
    private func yellowMeanX(_ image: CIImage) -> Double? {
        let context = CIContext(options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        let pixels = RenderFixture.Pixels(width: width, height: height, data: data)
        var count = 0, sumX = 0
        for y in 0..<height {
            for x in 0..<width {
                let c = pixels.rgb(x: x, y: y)
                if c.r > 200, c.g > 150, c.g < 240, c.b < 60 {
                    count += 1
                    sumX += x
                }
            }
        }
        return count > 100 ? Double(sumX) / Double(count) : nil
    }

    @Test func compositeHighlightsByTime() throws {
        let layer = FrameRenderer.TitleLayer(title: title, style: style,
                                             outputRange: TickRange(start: 600, duration: 600))
        let renderer = TitleRenderer()
        func frame(at time: Double) -> CIImage {
            FrameRenderer.composite([layer], over: FrameRenderer.black(renderSize: size),
                                    at: time, renderSize: size, titleRenderer: renderer)
        }
        // The title starts at 600: the first word is lit at 650 and stays lit
        // through the pause at 750; the second is lit from 800.
        let first = try #require(yellowMeanX(frame(at: 650)))
        let between = try #require(yellowMeanX(frame(at: 750)))
        let second = try #require(yellowMeanX(frame(at: 850)))
        #expect(first < Double(size.width) / 2)
        #expect(between == first)
        #expect(second > Double(size.width) / 2)
    }

    // MARK: Auto-Captions

    @Test func autoCaptionsFillWordTimesRelativeToTheTitle() throws {
        let project = Project(source: Fixture.source,
                              segments: [Fixture.video(1, start: 0, duration: 1200),
                                         Fixture.video(3, start: 1800, duration: 1200)])
        let words = [TranscriptWord(text: "Hello", start: 100, end: 200),
                     TranscriptWord(text: "world.", start: 250, end: 400),
                     TranscriptWord(text: "Cut", start: 1100, end: 1180),
                     TranscriptWord(text: "off", start: 1190, end: 1300)]
        var next = 100
        let titles = AutoCaptions.titles(for: words, in: project, style: StyleLibrary.highlight) {
            next += 1
            return Fixture.id(next)
        }
        #expect(titles.map(\.text) == ["Hello world.", "Cut off"])
        #expect(titles[0].words == [word("Hello", 0, 100), word("world.", 150, 300)])
        // "Cut off" runs into the cut at 1200 (100 ticks after it starts).
        #expect(titles[1].duration == 100)
        #expect(titles[1].words == [word("Cut", 0, 80), word("off", 90, 100)])
        for title in titles {
            #expect(WordHighlight.ranges(of: title.words ?? [], in: title.text) != nil)
        }
    }

    @Test func highlightBuiltIn() {
        let style = StyleLibrary.highlight
        #expect(style.id == UUID(uuidString: "7C1E0001-0000-4000-8000-00000000000E"))
        #expect(style.highlight != nil && style.stroke != nil)
        #expect(StyleLibrary.builtIns.last == style)
    }
}
