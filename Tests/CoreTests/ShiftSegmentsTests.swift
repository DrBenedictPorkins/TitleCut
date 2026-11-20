import Foundation
import Testing
@testable import TitleCutCore

/// Option-drag on a clip: it and everything after it move together
/// (`shiftSegments`).
@MainActor
struct ShiftSegmentsTests {
    typealias M = MoveFixture

    private func shift(_ n: Int, to start: Tick, in project: inout Project) -> Bool {
        ProjectCommand.shiftSegments(fromID: Fixture.id(n), toOutputStart: start,
                                     newGapID: Fixture.id(90)).apply(to: &project)
    }

    @Test func laterOpensAGapAndCarriesEverythingAfter() {
        let original = M.clips
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        #expect(store.perform(.shiftSegments(fromID: Fixture.id(2), toOutputStart: 900,
                                             newGapID: Fixture.id(90))))
        #expect(undo.undoActionName == "Move Segments")
        let project = store.project
        #expect(project.segments.map(\.id)
            == [Fixture.id(1), Fixture.id(90), Fixture.id(2), Fixture.id(3)])
        #expect(M.start(2, in: project) == 900)
        #expect(M.start(3, in: project) == 1500)
        // Title 10 rides on clip 2.
        #expect(project.titles == original.titles)
        #expect(TimelineMath.titleOutputRange(project.titles[0], in: project)?.start == 1000)

        undo.undo()
        #expect(store.project == original)
    }

    @Test func earlierNarrowsTheGapBeforeAndStopsAtThePreviousClip() {
        var project = M.clips
        #expect(shift(3, to: 1500, in: &project))
        #expect(shift(3, to: 1300, in: &project))
        #expect(M.start(3, in: project) == 1300)
        // Past the gap it closes it, and no further.
        #expect(shift(3, to: 200, in: &project))
        #expect(project == M.clips)
        // With no gap before, earlier changes nothing.
        #expect(shift(3, to: 900, in: &project))
        #expect(project == M.clips)
    }

    @Test func aDragBackToItsStartLeavesNothing() {
        let store = ProjectStore(project: M.clips)
        store.beginGesture(named: "Move Segments")
        let ahead = ProjectCommand.shiftSegments(fromID: Fixture.id(2), toOutputStart: 1000,
                                                 newGapID: Fixture.id(90))
        let back = ProjectCommand.shiftSegments(fromID: Fixture.id(2), toOutputStart: 600,
                                                newGapID: Fixture.id(90))
        #expect(store.performInGesture(ahead))
        #expect(store.performInGesture(back))
        store.endGesture()
        #expect(store.project == M.clips)
    }

    @Test func refusedForTheFirstSegmentOrAGap() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(2, duration: 300),
                              Fixture.video(3, start: 600, duration: 600)])
        let before = project
        #expect(!shift(1, to: 300, in: &project))
        #expect(!shift(2, to: 900, in: &project))
        #expect(project == before)
        // The gap before clip 3 is widened, keeping its ID.
        #expect(shift(3, to: 1000, in: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(2), Fixture.id(3)])
        #expect(project.segments[1].duration == 400)
    }
}
