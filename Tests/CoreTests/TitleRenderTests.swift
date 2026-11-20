import AVFoundation
import CoreImage
import CoreText
import Foundation
import Testing
@testable import TitleCutCore

// MARK: Easing

struct TitleRenderEasingTests {
    @Test(arguments: [Easing.linear, .easeIn, .easeOut, .easeInOut])
    func endpointsAndMonotonic(_ easing: Easing) {
        #expect(easing.value(at: 0) == 0)
        #expect(easing.value(at: 1) == 1)
        var previous = 0.0
        for step in 1...100 {
            let value = easing.value(at: Double(step) / 100)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test func midpoints() {
        #expect(Easing.linear.value(at: 0.5) == 0.5)
        #expect(abs(Easing.easeIn.value(at: 0.5) - 0.125) < 1e-12)
        #expect(abs(Easing.easeOut.value(at: 0.5) - 0.875) < 1e-12)
        #expect(abs(Easing.easeInOut.value(at: 0.5) - 0.5) < 1e-12)
        #expect(abs(Easing.easeInOut.value(at: 0.25) - 0.0625) < 1e-12)
        #expect(abs(Easing.easeInOut.value(at: 0.75) - 0.9375) < 1e-12)
    }

    @Test func clampsOutsideUnitRange() {
        #expect(Easing.easeOut.value(at: -1) == 0)
        #expect(Easing.easeIn.value(at: 2) == 1)
    }
}

// MARK: Transitions

struct TitleRenderTransitionTests {
    /// Title at output [1000, 2200), 300-tick transitions unless given.
    private func title(text: String = "abcdefghij", in kindIn: TransitionKind,
                       out kindOut: TransitionKind, inLength: Tick = 300,
                       outLength: Tick = 300, easing: Easing = .linear,
                       duration: Tick = 1200) -> Title {
        Title(id: Fixture.id(1), text: text,
              anchor: TitleAnchor(segmentID: Fixture.id(2), offset: 1000),
              duration: duration, styleID: Fixture.id(3),
              transitionIn: Transition(kind: kindIn, duration: inLength, easing: easing),
              transitionOut: Transition(kind: kindOut, duration: outLength, easing: easing))
    }

    private let range = TickRange(start: 1000, duration: 1200)

    private func at(_ title: Title, _ time: Tick,
                    range: TickRange? = nil) -> TitleAppearance? {
        TransitionEvaluator.appearance(of: title, outputRange: range ?? self.range, at: time)
    }

    @Test func inactiveOutsideRange() {
        let t = title(in: .fade, out: .fade)
        #expect(at(t, 999) == nil)
        #expect(at(t, 2200) == nil)
        #expect(at(t, 1000) != nil)
        #expect(at(t, 2199) != nil)
    }

    @Test func fadeInStartMiddleEnd() throws {
        let t = title(in: .fade, out: .none)
        #expect(try #require(at(t, 1000)).opacity == 0)
        #expect(abs(try #require(at(t, 1150)).opacity - 0.5) < 1e-9)
        #expect(try #require(at(t, 1300)).opacity == 1)
        #expect(try #require(at(t, 1600)).opacity == 1)
    }

    @Test func fadeOutStartMiddleEnd() throws {
        let t = title(in: .none, out: .fade)
        #expect(try #require(at(t, 1900)).opacity == 1)
        #expect(abs(try #require(at(t, 2050)).opacity - 0.5) < 1e-9)
        let last = try #require(at(t, 2199)).opacity
        #expect(last > 0 && last < 0.01)
        // Fractional time just before the end approaches 0.
        let end = try #require(TransitionEvaluator.appearance(of: t, outputRange: range,
                                                              at: 2199.999))
        #expect(end.opacity < 1e-4)
    }

    @Test func easingShapesProgress() throws {
        let t = title(in: .fade, out: .fade, easing: .easeIn)
        #expect(abs(try #require(at(t, 1150)).opacity - 0.125) < 1e-9)
        // Out: shown = 1 - easeIn(0.5).
        #expect(abs(try #require(at(t, 2050)).opacity - 0.875) < 1e-9)
    }

    @Test(arguments: [
        (SlideEdge.top, CGVector(dx: 0, dy: -1)),
        (SlideEdge.bottom, CGVector(dx: 0, dy: 1)),
        (SlideEdge.leading, CGVector(dx: -1, dy: 0)),
        (SlideEdge.trailing, CGVector(dx: 1, dy: 0)),
    ])
    func slideInFromEdge(_ edge: SlideEdge, _ direction: CGVector) throws {
        let t = title(in: .slide(edge: edge), out: .none)
        let start = try #require(at(t, 1000))
        #expect(start.offset == direction)
        #expect(start.opacity == 1)
        let mid = try #require(at(t, 1150))
        #expect(mid.offset == CGVector(dx: direction.dx / 2, dy: direction.dy / 2))
        #expect(try #require(at(t, 1300)).offset == .zero)
    }

    @Test func slideOutToEdge() throws {
        let t = title(in: .none, out: .slide(edge: .leading))
        #expect(try #require(at(t, 1900)).offset == .zero)
        #expect(try #require(at(t, 2050)).offset == CGVector(dx: -0.5, dy: 0))
        #expect(try #require(at(t, 2199)).offset.dx < -0.99)
    }

    @Test func scaleInAndOut() throws {
        let t = title(in: .scale, out: .scale)
        #expect(try #require(at(t, 1000)).scale == 0)
        #expect(abs(try #require(at(t, 1150)).scale - 0.5) < 1e-9)
        #expect(try #require(at(t, 1300)).scale == 1)
        #expect(try #require(at(t, 1900)).scale == 1)
        #expect(abs(try #require(at(t, 2050)).scale - 0.5) < 1e-9)
    }

    @Test func typewriterInAndOut() throws {
        let t = title(in: .typewriter, out: .typewriter)
        #expect(try #require(at(t, 1000)).visibleCharacters == 0)
        #expect(try #require(at(t, 1150)).visibleCharacters == 5)
        #expect(try #require(at(t, 1300)).visibleCharacters == 10)
        #expect(try #require(at(t, 1600)).visibleCharacters == 10)
        #expect(try #require(at(t, 1900)).visibleCharacters == 10)
        #expect(try #require(at(t, 2050)).visibleCharacters == 5)
        #expect(try #require(at(t, 2199)).visibleCharacters == 0)
        // Typewriter changes nothing else.
        let mid = try #require(at(t, 1150))
        #expect(mid.opacity == 1 && mid.scale == 1 && mid.offset == .zero)
    }

    @Test func typewriterCountsGraphemeClusters() throws {
        let t = title(text: "e\u{301}e\u{301}", in: .typewriter, out: .none)
        #expect(try #require(at(t, 1150)).visibleCharacters == 1)
    }

    @Test func noneIsIdentityThroughout() throws {
        let t = title(in: .none, out: .none)
        for time: Tick in [1000, 1150, 1600, 2050, 2199] {
            #expect(try #require(at(t, time)) == TitleAppearance(visibleCharacters: 10))
        }
    }

    @Test func noneTransitionHasNoLengthEvenWithDuration() {
        let lengths = TransitionEvaluator.transitionLengths(
            in: Transition(kind: .none, duration: 900, easing: .linear),
            out: Transition(kind: .fade, duration: 300, easing: .linear), titleLength: 600)
        #expect(lengths.in == 0 && lengths.out == 300)
    }

    @Test func shortTitleScalesTransitionsProportionally() throws {
        // 600-tick title, 600 in + 300 out → scaled by 600/900: 400 in, 200 out.
        let lengths = TransitionEvaluator.transitionLengths(
            in: Transition(kind: .fade, duration: 600, easing: .linear),
            out: Transition(kind: .fade, duration: 300, easing: .linear), titleLength: 600)
        #expect(abs(lengths.in - 400) < 1e-9)
        #expect(abs(lengths.out - 200) < 1e-9)

        let t = title(in: .fade, out: .fade, inLength: 600, outLength: 300, duration: 600)
        let short = TickRange(start: 1000, duration: 600)
        #expect(try #require(at(t, 1000, range: short)).opacity == 0)
        #expect(abs(try #require(at(t, 1200, range: short)).opacity - 0.5) < 1e-9)
        // In ends exactly where out begins: fully shown at that instant.
        #expect(try #require(at(t, 1400, range: short)).opacity == 1)
        #expect(abs(try #require(at(t, 1500, range: short)).opacity - 0.5) < 1e-9)
    }

    @Test func transitionsThatFitAreNotScaled() {
        let lengths = TransitionEvaluator.transitionLengths(
            in: Transition(kind: .fade, duration: 300, easing: .linear),
            out: Transition(kind: .scale, duration: 300, easing: .linear), titleLength: 600)
        #expect(lengths.in == 300 && lengths.out == 300)
    }

    @Test func clampedRangeEndsTheOutTransition() throws {
        // Title clamped by the end of the timeline: out completes at the clamp.
        let t = title(in: .none, out: .fade)
        let clamped = TickRange(start: 1000, duration: 600)
        #expect(abs(try #require(at(t, 1450, range: clamped)).opacity - 0.5) < 1e-9)
    }
}

// MARK: TitleRenderer

struct TitleRenderTitleRendererTests {
    private let hd = CGSize(width: 1920, height: 1080)

    private func style(ratio: Double = 0.06, maxWidth: Double = 0.8,
                       background: BackgroundBox? = nil) -> TitleStyle {
        TitleStyle(id: Fixture.id(800), name: "Test", fontName: "Helvetica Neue",
                   fontSizeRatio: ratio, weight: .bold, textColor: RGBA(red: 1, green: 1, blue: 1),
                   background: background, alignment: .center, position: .center,
                   maxWidthRatio: maxWidth)
    }

    private func title(_ text: String, overrides: StyleOverrides? = nil) -> Title {
        Title(id: Fixture.id(1), text: text,
              anchor: TitleAnchor(segmentID: Fixture.id(2), offset: 0),
              duration: 600, styleID: Fixture.id(800), styleOverrides: overrides)
    }

    /// Number of pixels with any coverage.
    private func opaquePixels(_ image: CGImage) -> Int {
        let pixels = RenderFixture.pixels(of: image)
        return stride(from: 3, to: pixels.data.count, by: 4).filter { pixels.data[$0] > 0 }.count
    }

    @Test(arguments: [StyleLibrary.meme, StyleLibrary.memeInverted])
    func memeStylesUseImpactAndDrawBothFillAndOutline(_ meme: TitleStyle) throws {
        let font = TitleRenderer.makeFont(name: meme.fontName, weight: meme.weight, size: 40)
        #expect(CTFontCopyFamilyName(font) as String == "Impact")
        let rendered = try #require(TitleRenderer.draw(text: "WHEN THE CODE COMPILES",
                                                       style: meme, renderSize: hd))
        let pixels = RenderFixture.pixels(of: rendered.image).data
        var light = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] == 255 {
            let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            if sum > 700 { light += 1 } else if sum < 60 { dark += 1 }
        }
        #expect(light > 500)
        #expect(dark > 500)
    }

    @Test func producesNonEmptyImage() throws {
        let rendered = try #require(TitleRenderer.draw(text: "Hello", style: style(),
                                                       renderSize: hd))
        #expect(rendered.image.width > 0 && rendered.image.height > 0)
        #expect(opaquePixels(rendered.image) > 100)
        let bounds = CGRect(x: 0, y: 0, width: rendered.image.width,
                            height: rendered.image.height)
        #expect(bounds.contains(rendered.contentRect))
    }

    @Test func sizeFollowsFontRatio() throws {
        let small = try #require(TitleRenderer.draw(text: "Hello", style: style(ratio: 0.04),
                                                    renderSize: hd))
        let large = try #require(TitleRenderer.draw(text: "Hello", style: style(ratio: 0.08),
                                                    renderSize: hd))
        #expect(large.contentRect.height > small.contentRect.height * 1.8)
        #expect(large.contentRect.width > small.contentRect.width * 1.8)
    }

    @Test func overrideFontRatioIsApplied() throws {
        let renderer = TitleRenderer()
        let plain = try #require(renderer.render(title("Hello"), style: style(ratio: 0.04),
                                                 renderSize: hd))
        let overridden = try #require(renderer.render(
            title("Hello", overrides: StyleOverrides(fontSizeRatio: 0.08)),
            style: style(ratio: 0.04), renderSize: hd))
        #expect(overridden.contentRect.height > plain.contentRect.height * 1.8)
    }

    @Test func sizeFollowsRenderHeight() throws {
        let sd = try #require(TitleRenderer.draw(text: "Hello", style: style(),
                                                 renderSize: CGSize(width: 640, height: 360)))
        let full = try #require(TitleRenderer.draw(text: "Hello", style: style(),
                                                   renderSize: hd))
        #expect(full.contentRect.height > sd.contentRect.height * 2.5)
    }

    @Test func wrapsAtMaxWidth() throws {
        let text = "The quick brown fox jumps over the lazy dog"
        let wide = try #require(TitleRenderer.draw(text: text, style: style(maxWidth: 0.9),
                                                   renderSize: hd))
        let narrow = try #require(TitleRenderer.draw(text: text, style: style(maxWidth: 0.2),
                                                     renderSize: hd))
        #expect(narrow.contentRect.height > wide.contentRect.height * 2)
        #expect(narrow.contentRect.width <= 0.2 * hd.width + 2)
    }

    @Test func backgroundPaddingGrowsTheBox() throws {
        let bare = try #require(TitleRenderer.draw(text: "Hi", style: style(), renderSize: hd))
        let boxed = try #require(TitleRenderer.draw(
            text: "Hi", style: style(background: BackgroundBox(
                color: RGBA(red: 0, green: 0, blue: 0), paddingRatio: 0.5,
                cornerRadiusRatio: 0)), renderSize: hd))
        let padding = 0.5 * 0.06 * hd.height
        #expect(abs(boxed.contentRect.width - bare.contentRect.width - 2 * padding) <= 2)
    }

    @Test func emptyTextDrawsNothing() {
        #expect(TitleRenderer.draw(text: "", style: style(), renderSize: hd) == nil)
    }

    @Test func typewriterKeepsLayoutAndHidesCharacters() throws {
        let full = try #require(TitleRenderer.draw(text: "Hello world", style: style(),
                                                   renderSize: hd))
        let none = try #require(TitleRenderer.draw(text: "Hello world", style: style(),
                                                   renderSize: hd, visibleCharacters: 0))
        let some = try #require(TitleRenderer.draw(text: "Hello world", style: style(),
                                                   renderSize: hd, visibleCharacters: 5))
        #expect(none.contentRect == full.contentRect)
        #expect(some.contentRect == full.contentRect)
        #expect(opaquePixels(none.image) == 0)
        let partial = opaquePixels(some.image)
        #expect(partial > 0 && partial < opaquePixels(full.image))
    }

    @Test func cacheReusesAndInvalidates() throws {
        let renderer = TitleRenderer()
        let a = try #require(renderer.render(title("Hello"), style: style(), renderSize: hd))
        let b = try #require(renderer.render(title("Hello"), style: style(), renderSize: hd))
        #expect(a.image === b.image)

        let text = try #require(renderer.render(title("Hello!"), style: style(), renderSize: hd))
        #expect(text.image !== a.image)
        var restyled = style()
        restyled.textColor = RGBA(red: 1, green: 0, blue: 0)
        let colour = try #require(renderer.render(title("Hello!"), style: restyled,
                                                  renderSize: hd))
        #expect(colour.image !== text.image)
        let resized = try #require(renderer.render(title("Hello!"), style: restyled,
                                                   renderSize: CGSize(width: 1280, height: 720)))
        #expect(resized.image !== colour.image)
        // Back to an earlier input renders afresh: the cache keeps one input per title.
        let again = try #require(renderer.render(title("Hello"), style: style(), renderSize: hd))
        #expect(again.image !== a.image)
    }

    @Test func concurrentRendersAgree() async throws {
        let renderer = TitleRenderer()
        let style = style()
        let title = title("Concurrent")
        let size = hd
        let widths = await withTaskGroup(of: Int.self) { group in
            for n in 0..<16 {
                group.addTask {
                    renderer.render(title, style: style, renderSize: size,
                                    visibleCharacters: n % 4 == 0 ? nil : n % 10)?.image.width ?? 0
                }
            }
            return await group.reduce(into: Set<Int>()) { $0.insert($1) }
        }
        #expect(widths.count == 1 && !widths.contains(0))
    }
}

// MARK: FrameRenderer step 2 (no AVFoundation)

struct TitleRenderFrameTests {
    private let size = CGSize(width: 400, height: 200)

    /// White text on a white box, so the whole box is one colour.
    private func layer(position: NormalizedPosition = .center, fadeIn: Tick = 0,
                       start: Tick = 0, duration: Tick = 1200) -> FrameRenderer.TitleLayer {
        let style = TitleStyle(
            id: Fixture.id(800), name: "Box", fontName: "Helvetica Neue", fontSizeRatio: 0.1,
            weight: .bold, textColor: RGBA(red: 1, green: 1, blue: 1),
            background: BackgroundBox(color: RGBA(red: 1, green: 1, blue: 1),
                                      paddingRatio: 0.5, cornerRadiusRatio: 0),
            alignment: .center, position: position, maxWidthRatio: 0.8)
        let title = Title(id: Fixture.id(1), text: "Hi",
                          anchor: TitleAnchor(segmentID: Fixture.id(2), offset: start),
                          duration: duration, styleID: style.id,
                          transitionIn: Transition(kind: fadeIn > 0 ? .fade : .none,
                                                   duration: fadeIn, easing: .linear))
        return FrameRenderer.TitleLayer(title: title, style: style,
                                        outputRange: TickRange(start: start, duration: duration))
    }

    /// Renders like the compositor: no colour management.
    private func pixels(_ image: CIImage) -> RenderFixture.Pixels {
        let context = CIContext(options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                       colorSpace: nil)
        // Rows come out top row first.
        return RenderFixture.Pixels(width: width, height: height, data: data)
    }

    private var black: CIImage { FrameRenderer.black(renderSize: size) }

    @Test func titleDrawnOnlyWhileActive() {
        let layer = layer(start: 600, duration: 600)
        for (time, drawn) in [(599.0, false), (600.0, true), (900.0, true), (1199.0, true),
                              (1200.0, false)] {
            let image = FrameRenderer.composite([layer], over: black, at: time,
                                                renderSize: size, titleRenderer: TitleRenderer())
            #expect(image.extent == CGRect(origin: .zero, size: size))
            let centre = pixels(image).rgb(x: 200, y: 100)
            #expect((centre.r > 250) == drawn, "t=\(time): \(centre)")
        }
    }

    @Test func fadeHalfwayIsHalfOpacity() {
        let image = FrameRenderer.composite([layer(fadeIn: 600)], over: black, at: 300,
                                            renderSize: size, titleRenderer: TitleRenderer())
        let centre = pixels(image).rgb(x: 200, y: 100)
        #expect(abs(centre.r - 127.5) <= 2, "\(centre)")
    }

    @Test func customPositionCentresTheBox() {
        let image = FrameRenderer.composite([layer(position: .custom(x: 0.25, y: 0.25))],
                                            over: black, at: 0, renderSize: size,
                                            titleRenderer: TitleRenderer())
        let p = pixels(image)
        #expect(p.rgb(x: 100, y: 50).r > 250)
        #expect(p.rgb(x: 300, y: 150).r < 5)
    }

    @Test func positionOverrideWins() {
        var layer = layer(position: .center)
        layer.title.styleOverrides = StyleOverrides(position: .custom(x: 0.75, y: 0.75))
        let image = FrameRenderer.composite([layer], over: black, at: 0, renderSize: size,
                                            titleRenderer: TitleRenderer())
        let p = pixels(image)
        #expect(p.rgb(x: 300, y: 150).r > 250)
        #expect(p.rgb(x: 200, y: 100).r < 5)
    }

    @Test func laterStartIsOnTop() {
        var red = layer(start: 300)
        red.title.id = Fixture.id(5)
        red.style.background?.color = RGBA(red: 1, green: 0, blue: 0)
        red.style.textColor = RGBA(red: 1, green: 0, blue: 0)
        // Red starts later but comes first in the array: it must still be on top.
        let image = FrameRenderer.composite([red, layer(start: 0)], over: black, at: 600,
                                            renderSize: size, titleRenderer: TitleRenderer())
        let centre = pixels(image).rgb(x: 200, y: 100)
        #expect(centre.r > 250 && centre.g < 5, "\(centre)")
    }

    @Test(arguments: [NormalizedPosition.top, .center, .lowerThird, .bottom])
    func presetFramesStayOnScreen(_ position: NormalizedPosition) {
        let render = CGSize(width: 1920, height: 1080)
        for alignment in [TextAlignment.leading, .center, .trailing] {
            let frame = FrameRenderer.titleFrame(contentSize: CGSize(width: 600, height: 100),
                                                 position: position, alignment: alignment,
                                                 renderSize: render)
            #expect(CGRect(origin: .zero, size: render).contains(frame))
        }
    }

    @Test func presetVerticalOrder() {
        let render = CGSize(width: 1920, height: 1080)
        let content = CGSize(width: 600, height: 100)
        let y = { (p: NormalizedPosition) in
            FrameRenderer.titleFrame(contentSize: content, position: p, alignment: .center,
                                     renderSize: render).midY
        }
        #expect(y(.top) < y(.center))
        #expect(y(.center) < y(.lowerThird))
        #expect(y(.lowerThird) < y(.bottom))
    }
}

// MARK: Composition and compositor

@Suite(.serialized)
struct TitleRenderCompositionTests {
    /// White box centred on the frame.
    private let style = TitleStyle(
        id: Fixture.id(800), name: "Box", fontName: "Helvetica Neue", fontSizeRatio: 0.1,
        weight: .bold, textColor: RGBA(red: 0, green: 0, blue: 0),
        background: BackgroundBox(color: RGBA(red: 1, green: 1, blue: 1),
                                  paddingRatio: 0.5, cornerRadiusRatio: 0),
        alignment: .center, position: .center, maxWidthRatio: 0.8)

    /// Fixture project with one title over output [1 s, 2 s).
    private func project(for url: URL) async throws -> Project {
        var project = Project.empty
        let source = try await SourceVideo.load(from: url)
        ProjectCommand.setSource(source, segmentID: Fixture.id(1)).apply(to: &project)
        project.styles = [style]
        project.titles = [Title(id: Fixture.id(10), text: "Title",
                                anchor: TitleAnchor(segmentID: Fixture.id(1), offset: 600),
                                duration: 600, styleID: style.id)]
        return project
    }

    /// A point inside the box's left padding, where the box colour shows.
    private func paddingPoint(renderSize: CGSize) throws -> (x: Int, y: Int) {
        let rendered = try #require(TitleRenderer.draw(text: "Title", style: style,
                                                       renderSize: renderSize))
        let frame = FrameRenderer.titleFrame(contentSize: rendered.contentRect.size,
                                             position: .center, alignment: .center,
                                             renderSize: renderSize)
        return (Int(frame.minX) + 6, Int(frame.midY))
    }

    private func distance(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g)
            + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    private func expect(project: Project, url: URL, frame: Int, titleShown: Bool,
                        source: Int? = nil) async throws {
        let seconds = (Double(frame) + 0.5) / Double(RenderFixture.fps)
        let rendered = try await RenderFixture.frame(of: project, from: url, at: seconds)
        let point = try paddingPoint(renderSize: RenderFixture.size)
        let pixel = rendered.rgb(x: point.x, y: point.y)
        let reference = try await RenderFixture.directFrame(source ?? frame, from: url)
        let background = reference.rgb(x: point.x, y: point.y)
        if titleShown {
            #expect(pixel.r > 245 && pixel.g > 245 && pixel.b > 245,
                    "frame \(frame): expected box, got \(pixel)")
        } else {
            #expect(distance(pixel, background) <= 2,
                    "frame \(frame): expected background \(background), got \(pixel)")
        }
    }

    @Test func titleRegionDiffersOnlyWhileActive() async throws {
        let url = try await RenderFixture.numbered.value
        let project = try await project(for: url)
        for (frame, shown) in [(15, false), (29, false), (30, true), (45, true), (59, true),
                               (60, false), (90, false)] {
            try await expect(project: project, url: url, frame: frame, titleShown: shown)
        }
    }

    @Test func titleRunsAcrossASegmentBoundary() async throws {
        let url = try await RenderFixture.numbered.value
        var project = try await project(for: url)
        // Split at 1.5 s: the title is anchored to the first half and runs into the second.
        ProjectCommand.splitSegment(atOutputTime: 900, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        #expect(project.titles[0].anchor.segmentID == Fixture.id(1))
        for (frame, shown) in [(40, true), (50, true), (65, false)] {
            try await expect(project: project, url: url, frame: frame, titleShown: shown)
        }
    }

    @Test func instructionsCarryOverlappingTitles() async throws {
        let url = try await RenderFixture.numbered.value
        var project = try await project(for: url)
        ProjectCommand.splitSegment(atOutputTime: 900, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 2400, newSegmentID: Fixture.id(3))
            .apply(to: &project)
        // A title whose style is missing is not drawn.
        project.titles.append(Title(id: Fixture.id(11), text: "x",
                                    anchor: TitleAnchor(segmentID: Fixture.id(3), offset: 0),
                                    duration: 60, styleID: Fixture.id(999)))

        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        let instructions = try #require(built.videoComposition?.instructions
            as? [TitleCutInstruction])
        #expect(instructions.map { $0.titles.map(\.title.id) }
                == [[Fixture.id(10)], [Fixture.id(10)], []])
        let layer = try #require(instructions.first?.titles.first)
        #expect(layer.style == style)
        #expect(layer.outputRange == TickRange(start: 600, duration: 600))
    }

    @Test func titleLayersClampToOutputEnd() {
        var project = Fixture.single
        project.styles = [style]
        project.titles = [Fixture.title(10, segment: 1, offset: 2800, duration: 600)]
        let layers = CompositionBuilder.titleLayers(project)
        #expect(layers.map(\.outputRange) == [TickRange(start: 2800, duration: 200)])
    }
}
