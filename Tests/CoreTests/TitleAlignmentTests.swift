import CoreGraphics
import Foundation
import Testing
@testable import TitleCutCore

/// ALIGN moving titles that have a custom position.
@Suite struct TitleAlignmentTests {
    @Test func centreXMatchesThePresetLayout() {
        let render = CGSize(width: 1000, height: 500)
        for alignment in [TextAlignment.leading, .center, .trailing] {
            let preset = FrameRenderer.titleFrame(contentSize: CGSize(width: 200, height: 50),
                                                  position: .top, alignment: alignment,
                                                  renderSize: render)
            let x = FrameRenderer.alignedCentreX(contentWidth: 200, alignment: alignment,
                                                 renderWidth: render.width)
            #expect(abs(x - preset.midX / render.width) < 1e-9)
        }
    }

    @Test func movesOnlyCustomTitlesAndKeepsHeight() throws {
        let style = try #require(StyleLibrary.builtIns.first)
        var custom = Fixture.title(10, segment: 1, offset: 0)
        custom.styleID = style.id
        custom.styleOverrides = StyleOverrides(position: .custom(x: 0.5, y: 0.3))
        var preset = Fixture.title(11, segment: 1, offset: 0)
        preset.styleID = style.id
        preset.styleOverrides = StyleOverrides(position: .top)
        let moves = FrameRenderer.alignmentMoves([custom, preset], to: .leading,
                                                 style: { _ in style },
                                                 renderer: TitleRenderer(),
                                                 renderSize: CGSize(width: 1920, height: 1080))
        #expect(moves.count == 1)
        guard case let .setTitleStyleOverrides(id, overrides?) = try #require(moves.first),
              case let .custom(x, y)? = overrides.position else {
            Issue.record("expected a custom position")
            return
        }
        #expect(id == custom.id)
        #expect(y == 0.3)
        #expect(x < 0.5 && x > FrameRenderer.safeMargin)
    }

    @Test func aTitlesOwnSideOverridesItsStyle() throws {
        let style = try #require(StyleLibrary.builtIns.first { $0.alignment == .leading })
        let overrides = StyleOverrides(position: .bottom, alignment: .trailing)
        let effective = style.applying(overrides)
        #expect(effective.alignment == .trailing)
        #expect(effective.position == .bottom)
        // Bottom right: right edge and bottom edge on the margins.
        let render = CGSize(width: 1000, height: 500)
        let frame = FrameRenderer.titleFrame(contentSize: CGSize(width: 200, height: 50),
                                             position: effective.position,
                                             alignment: effective.alignment, renderSize: render)
        #expect(abs(frame.maxX - (1 - FrameRenderer.safeMargin) * 1000) < 1e-9)
        #expect(abs(frame.maxY - (1 - FrameRenderer.safeMargin) * 500) < 1e-9)
        #expect(style.applying(StyleOverrides(position: .top)).alignment == .leading)
    }

    @Test func overridesSavedBeforeSidesStillOpen() throws {
        let saved = Data(#"{"position":{"top":{}},"fontSizeRatio":0.08}"#.utf8)
        let overrides = try JSONDecoder().decode(StyleOverrides.self, from: saved)
        #expect(overrides == StyleOverrides(position: .top, fontSizeRatio: 0.08))
        let again = try JSONDecoder().decode(StyleOverrides.self, from: JSONEncoder().encode(
            StyleOverrides(alignment: .center)))
        #expect(again.alignment == .center)
    }

    @Test func aBoxCanStretchAcrossTheFrame() throws {
        var style = try #require(StyleLibrary.builtIns.first { $0.background != nil })
        style.alignment = .leading
        let render = CGSize(width: 720, height: 1280)
        let fitted = try #require(TitleRenderer.draw(text: "Hi", style: style,
                                                     renderSize: render))
        #expect(fitted.contentRect.width < 360)
        style.background?.widthRatio = 1
        let full = try #require(TitleRenderer.draw(text: "Hi", style: style, renderSize: render))
        #expect(full.contentRect.width == 720)
        #expect(full.contentRect.height == fitted.contentRect.height)
        // Edge to edge, the margin gives way so the box stays on the frame.
        let frame = FrameRenderer.titleFrame(contentSize: full.contentRect.size,
                                             position: .lowerThird, alignment: .leading,
                                             renderSize: render)
        #expect(frame.minX == 0)
        let saved = Data(#"{"color":{"red":0,"green":0,"blue":0,"alpha":1},"paddingRatio":0.3,"cornerRadiusRatio":0.1}"#.utf8)
        #expect(try JSONDecoder().decode(BackgroundBox.self, from: saved).widthRatio == nil)
    }
}
