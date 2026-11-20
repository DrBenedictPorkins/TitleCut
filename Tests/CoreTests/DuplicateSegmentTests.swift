import Foundation
import Testing
@testable import TitleCutCore

/// Duplicate on a selected clip: a copy right after it (`duplicateSegment`).
@MainActor
struct DuplicateSegmentTests {
    typealias M = MoveFixture

    private let dip = ClipTransition(kind: .dipToBlack, duration: 300)

    @Test func theCopyFollowsTheClipAndLaterSegmentsMoveRight() {
        var original = M.clips
        original.segments[1].transitionIn = dip
        original.segments[2].transitionIn = dip
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        #expect(store.perform(.duplicateSegment(id: Fixture.id(2), newID: Fixture.id(20))))
        #expect(undo.undoActionName == "Duplicate Segment")
        let project = store.project
        #expect(project.segments.map(\.id)
            == [Fixture.id(1), Fixture.id(2), Fixture.id(20), Fixture.id(3)])
        guard case .video(let copy) = project.segments[2] else {
            Issue.record("The copy is not a video clip")
            return
        }
        #expect(copy.sourceRange == TickRange(start: 600, duration: 600))
        // No transition between the clip and its copy; the next cut keeps its own.
        #expect(project.segments[1].transitionIn == dip)
        #expect(copy.transitionIn == nil)
        #expect(project.segments[3].transitionIn == dip)
        #expect(M.start(3, in: project) == 1800)
        #expect(TimelineMath.outputDuration(project) == 2400)
        // Titles stay with their clip and are not copied.
        #expect(project.titles == original.titles)

        undo.undo()
        #expect(store.project == original)
    }

    @Test func theLastClipsCopyTakesTheEndTransition() {
        var project = M.clips
        project.segments[2].transitionOut = dip
        #expect(ProjectCommand.duplicateSegment(id: Fixture.id(3), newID: Fixture.id(20))
            .apply(to: &project))
        #expect(project.segments[2].transitionOut == nil)
        #expect(project.segments[3].id == Fixture.id(20))
        #expect(project.segments[3].transitionOut == dip)
    }

    @Test func refusedForAGapAMissingClipOrATakenID() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(2, duration: 300)])
        let before = project
        #expect(!ProjectCommand.duplicateSegment(id: Fixture.id(2), newID: Fixture.id(20))
            .apply(to: &project))
        #expect(!ProjectCommand.duplicateSegment(id: Fixture.id(9), newID: Fixture.id(20))
            .apply(to: &project))
        #expect(!ProjectCommand.duplicateSegment(id: Fixture.id(1), newID: Fixture.id(2))
            .apply(to: &project))
        #expect(project == before)
    }
}
