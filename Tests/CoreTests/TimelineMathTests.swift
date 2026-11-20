import Foundation
import Testing
@testable import TitleCutCore

struct TimelineMathTests {
    let project = Fixture.threeSegments

    @Test func outputDurationSumsSegments() {
        #expect(TimelineMath.outputDuration(project) == 3000)
        #expect(TimelineMath.outputDuration(.empty) == 0)
    }

    @Test func segmentStarts() {
        #expect(TimelineMath.segmentStart(Fixture.id(1), in: project) == 0)
        #expect(TimelineMath.segmentStart(Fixture.id(2), in: project) == 1200)
        #expect(TimelineMath.segmentStart(Fixture.id(3), in: project) == 1800)
        #expect(TimelineMath.segmentStart(Fixture.id(99), in: project) == nil)
    }

    @Test func segmentRange() {
        #expect(TimelineMath.segmentRange(Fixture.id(2), in: project)
                == TickRange(start: 1200, duration: 600))
        #expect(TimelineMath.segmentRange(Fixture.id(99), in: project) == nil)
    }

    @Test func locateInsideSegments() {
        #expect(TimelineMath.locate(0, in: project)
                == .init(segmentID: Fixture.id(1), index: 0, offset: 0))
        #expect(TimelineMath.locate(1199, in: project)
                == .init(segmentID: Fixture.id(1), index: 0, offset: 1199))
        #expect(TimelineMath.locate(1500, in: project)
                == .init(segmentID: Fixture.id(2), index: 1, offset: 300))
    }

    @Test func locateOnBoundaryBelongsToLaterSegment() {
        #expect(TimelineMath.locate(1200, in: project)
                == .init(segmentID: Fixture.id(2), index: 1, offset: 0))
        #expect(TimelineMath.locate(1800, in: project)
                == .init(segmentID: Fixture.id(3), index: 2, offset: 0))
    }

    @Test func locateAtEndIsLastSegmentEnd() {
        #expect(TimelineMath.locate(3000, in: project)
                == .init(segmentID: Fixture.id(3), index: 2, offset: 1200))
    }

    @Test func locateOutsideTimelineIsNil() {
        #expect(TimelineMath.locate(-1, in: project) == nil)
        #expect(TimelineMath.locate(3001, in: project) == nil)
        #expect(TimelineMath.locate(0, in: .empty) == nil)
    }

    @Test func sourceTime() {
        #expect(TimelineMath.sourceTime(0, in: project) == 0)
        #expect(TimelineMath.sourceTime(1199, in: project) == 1199)
        #expect(TimelineMath.sourceTime(1200, in: project) == nil)   // still starts here
        #expect(TimelineMath.sourceTime(1799, in: project) == nil)
        #expect(TimelineMath.sourceTime(1800, in: project) == 1200)  // boundary → later video
        #expect(TimelineMath.sourceTime(2999, in: project) == 2399)
        #expect(TimelineMath.sourceTime(3000, in: project) == 2400)
        #expect(TimelineMath.sourceTime(4000, in: project) == nil)
    }

    @Test func titleOutputRange() {
        let first = project.titles[0]
        #expect(TimelineMath.titleOutputRange(first, in: project)
                == TickRange(start: 100, duration: 300))
        // Titles may run past their segment into the next one.
        var long = first
        long.duration = 1500
        #expect(TimelineMath.titleOutputRange(long, in: project)
                == TickRange(start: 100, duration: 1500))
    }

    @Test func titleOutputRangeClampsToOutputDuration() {
        var title = Fixture.title(20, segment: 3, offset: 1000, duration: 600)
        #expect(TimelineMath.titleOutputRange(title, in: project)
                == TickRange(start: 2800, duration: 200))
        title.anchor.offset = 5000
        #expect(TimelineMath.titleOutputRange(title, in: project)
                == TickRange(start: 3000, duration: 0))
    }

    @Test func titleOutputRangeMissingSegmentIsNil() {
        let orphan = Fixture.title(20, segment: 99, offset: 0)
        #expect(TimelineMath.titleOutputRange(orphan, in: project) == nil)
    }

    @Test func splitVideo() throws {
        let (first, second) = try #require(
            TimelineMath.split(Fixture.video(1, start: 600, duration: 1200),
                               at: 300, newID: Fixture.id(50)))
        #expect(first == Fixture.video(1, start: 600, duration: 300))
        #expect(second == Fixture.video(50, start: 900, duration: 900))
    }

    @Test func splitStillPartitionsKeyframes() throws {
        let still = Segment.still(StillSegment(id: Fixture.id(2), stillID: Fixture.id(900),
                                               duration: 600, zoom: [
            ZoomKeyframe(time: 0, center: .zero, scale: 1, easing: .linear),
            ZoomKeyframe(time: 200, center: .zero, scale: 2, easing: .linear),
            ZoomKeyframe(time: 500, center: .zero, scale: 3, easing: .linear),
        ]))
        let (first, second) = try #require(TimelineMath.split(still, at: 200,
                                                               newID: Fixture.id(50)))
        guard case .still(let a) = first, case .still(let b) = second else {
            Issue.record("expected stills"); return
        }
        #expect(a.duration == 200 && b.duration == 400)
        #expect(a.zoom.map(\.time) == [0])
        #expect(b.zoom.map(\.time) == [0, 300])
        #expect(b.id == Fixture.id(50) && b.stillID == Fixture.id(900))
    }

    @Test(arguments: [Tick(0), 1200, -1, 1500])
    func splitAtEdgeOrOutsideIsRejected(offset: Tick) {
        #expect(TimelineMath.split(Fixture.video(1, start: 0, duration: 1200),
                                   at: offset, newID: Fixture.id(50)) == nil)
    }

    @Test func tickConversions() {
        #expect(Ticks.from(seconds: 1.5) == 900)
        #expect(Ticks.from(seconds: .nan) == 0)
        #expect(Ticks.seconds(450) == 0.75)
        #expect(Ticks.from(Ticks.cmTime(1234)) == 1234)
        #expect(TickRange(start: 10, duration: 5).contains(10))
        #expect(!TickRange(start: 10, duration: 5).contains(15))
    }
}
