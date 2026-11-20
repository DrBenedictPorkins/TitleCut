import Foundation
import Testing
@testable import TitleCutCore

struct TimelineViewportTests {
    // 3000 ticks over 300 pt: fit is 10 ticks per point. At 30 fps the
    // closest zoom is 20 / 8 = 2.5 ticks per point.
    let total: Tick = 3000
    let width = 300.0
    let fps = 30.0

    @Test func defaultIsFitWithNothingToScroll() {
        let viewport = TimelineViewport()
        #expect(viewport.isFit)
        #expect(viewport.resolvedTicksPerPoint(total: total, width: width, frameRate: fps) == 10)
        #expect(viewport.visibleRange(total: total, width: width, frameRate: fps) == 0...3000)
        #expect(TimelineViewport.fitTicksPerPoint(total: 0, width: width) == 0)
    }

    @Test func zoomKeepsTheAnchorUnderThePointer() {
        var viewport = TimelineViewport()
        // Tick 1500 sits at x 150 at fit; zoom 2x around it.
        viewport.zoom(by: 2, anchorTick: 1500, anchorX: 150, total: total, width: width,
                      frameRate: fps)
        #expect(viewport.ticksPerPoint == 5)
        #expect(viewport.visibleRange(total: total, width: width, frameRate: fps) == 750...2250)
        // Tick 2000 at x 250: it stays at x 250.
        viewport.zoom(by: 2, anchorTick: 2000, anchorX: 250, total: total, width: width,
                      frameRate: fps)
        let range = viewport.visibleRange(total: total, width: width, frameRate: fps)
        #expect(range.lowerBound + 250 * 2.5 == 2000)
    }

    @Test func zoomStopsAtOneFramePerEightPointsAndReturnsToFit() {
        var viewport = TimelineViewport()
        viewport.zoom(by: 1000, anchorTick: 0, anchorX: 0, total: total, width: width,
                      frameRate: fps)
        #expect(viewport.ticksPerPoint == 2.5)
        viewport.zoom(by: 0.001, anchorTick: 0, anchorX: 0, total: total, width: width,
                      frameRate: fps)
        #expect(viewport.isFit)
        #expect(viewport.start == 0)
    }

    @Test func scrollAndStartAreClampedToTheTimeline() {
        var viewport = TimelineViewport(ticksPerPoint: 5)
        viewport.scroll(byPoints: -100, total: total, width: width, frameRate: fps)
        #expect(viewport.start == 0)
        viewport.scroll(byPoints: 10_000, total: total, width: width, frameRate: fps)
        #expect(viewport.visibleRange(total: total, width: width, frameRate: fps) == 1500...3000)
        // A shorter timeline pulls the view back in.
        #expect(viewport.resolvedStart(total: 2000, width: width, frameRate: fps) == 500)
        // A held zoom wider than the new fit becomes fit.
        #expect(viewport.resolvedTicksPerPoint(total: 1000, width: width, frameRate: fps)
                == 1000.0 / 300)
    }

    @Test func revealPagesOnlyWhenOutside() {
        var viewport = TimelineViewport(ticksPerPoint: 5, start: 0)    // 0...1500 visible
        let moved1400 = viewport.reveal(1400, total: total, width: width, frameRate: fps)
        #expect(!moved1400)
        let moved1500 = viewport.reveal(1500, total: total, width: width, frameRate: fps)
        #expect(moved1500)
        #expect(viewport.visibleRange(total: total, width: width, frameRate: fps) == 1500...3000)
        let moved100 = viewport.reveal(100, total: total, width: width, frameRate: fps)
        #expect(moved100)
        #expect(viewport.start == 100)
    }

    @Test func rulerStepSuitsTheZoom() {
        // 56 pt at fit of a 5 s timeline over 300 pt: 560 ticks -> 1 s.
        #expect(TimelineViewport.rulerStep(ticksPerPoint: 10, frameRate: 30) == 600)
        // Closest zoom: 2.5 ticks/pt * 56 = 140 ticks -> 10 frames (200 ticks).
        #expect(TimelineViewport.rulerStep(ticksPerPoint: 2.5, frameRate: 30) == 200)
        #expect(TimelineViewport.rulerStep(ticksPerPoint: 0.1, frameRate: 30) == 20)
        // An hour over 300 pt: 7200 ticks/pt * 56 = 11.2 min -> 15 min.
        #expect(TimelineViewport.rulerStep(ticksPerPoint: 7200, frameRate: 30)
                == 15 * 60 * 600)
    }

    @Test func commandScrollMapsToSmoothZoomSteps() {
        let notch = TimelineViewport.zoomFactor(scrollDelta: 1, isPrecise: false)
        #expect(abs(notch - exp(0.12)) < 1e-12)
        #expect(TimelineViewport.zoomFactor(scrollDelta: -1, isPrecise: false) < 1)
        // Up then down by the same amount comes back exactly.
        #expect(abs(notch * TimelineViewport.zoomFactor(scrollDelta: -1, isPrecise: false) - 1)
                < 1e-12)
        // Many small trackpad deltas add up to one large one.
        let small = (0..<10).reduce(1.0) { factor, _ in
            factor * TimelineViewport.zoomFactor(scrollDelta: 10, isPrecise: true)
        }
        #expect(abs(small - TimelineViewport.zoomFactor(scrollDelta: 100, isPrecise: true)) < 1e-9)
        #expect(TimelineViewport.zoomFactor(scrollDelta: 0, isPrecise: true) == 1)
        #expect(TimelineViewport.zoomFactor(scrollDelta: .nan, isPrecise: true) == 1)
    }

    @Test func rulerLabels() {
        #expect(TimelineViewport.rulerLabel(600 * 75, step: 600, frameRate: 30) == "1:15")
        #expect(TimelineViewport.rulerLabel(600 + 200, step: 200, frameRate: 30) == "0:01:10")
        #expect(TimelineViewport.rulerLabel(600 * 3725, step: 600 * 60, frameRate: 30)
                == "1:02:05")
    }
}
