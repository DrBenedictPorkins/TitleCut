import Foundation
import Testing
@testable import TitleCutCore

struct TrimCommandTests {
    private func trim(_ n: Int, start: Tick, duration: Tick) -> ProjectCommand {
        .trimSegment(id: Fixture.id(n), sourceRange: TickRange(start: start, duration: duration))
    }

    private func sourceRange(_ n: Int, in project: Project) -> TickRange? {
        guard case .video(let video) = project.segments.first(where: { $0.id == Fixture.id(n) })
        else { return nil }
        return video.sourceRange
    }

    private func offset(_ n: Int, in project: Project) -> Tick? {
        project.titles.first { $0.id == Fixture.id(n) }?.anchor.offset
    }

    // MARK: Left edge

    @Test func extendLeftRevealsSourceAndShiftsTitleOffsets() {
        var project = Fixture.threeSegments
        #expect(trim(3, start: 900, duration: 1500).apply(to: &project))
        #expect(sourceRange(3, in: project) == TickRange(start: 900, duration: 1500))
        // Title 11 stays on source frame 1200.
        #expect(offset(11, in: project) == 300)
        #expect(TimelineMath.sourceTime(1800 + 300, in: project) == 1200)
        #expect(offset(10, in: project) == 100)
        #expect(TimelineMath.segmentStart(Fixture.id(3), in: project) == 1800)
        #expect(TimelineMath.outputDuration(project) == 3300)
    }

    @Test func trimLeftShiftsTitleOffsetsAndClampsToSegmentStart() {
        var project = Fixture.single
        #expect(trim(1, start: 600, duration: 2400).apply(to: &project))
        #expect(sourceRange(1, in: project) == TickRange(start: 600, duration: 2400))
        #expect(offset(10, in: project) == 0)       // source 300 was trimmed away
        #expect(offset(11, in: project) == 600)     // source 1200
        #expect(offset(12, in: project) == 1800)    // source 2400
        #expect(project.titles.map(\.anchor.segmentID).allSatisfy { $0 == Fixture.id(1) })
    }

    // MARK: Right edge

    @Test func extendRightKeepsOffsetsAndRipplesLaterSegments() throws {
        var project = Fixture.threeSegments
        #expect(trim(1, start: 0, duration: 1500).apply(to: &project))
        #expect(offset(10, in: project) == 100)
        #expect(offset(11, in: project) == 0)
        #expect(TimelineMath.segmentStart(Fixture.id(2), in: project) == 1500)
        #expect(TimelineMath.segmentStart(Fixture.id(3), in: project) == 2100)
        let title = try #require(project.titles.first { $0.id == Fixture.id(11) })
        #expect(TimelineMath.titleOutputRange(title, in: project)?.start == 2100)
    }

    @Test func trimRightClampsTitlesToLastTick() {
        var project = Fixture.single
        #expect(trim(1, start: 0, duration: 2000).apply(to: &project))
        #expect(offset(10, in: project) == 300)
        #expect(offset(11, in: project) == 1200)
        #expect(offset(12, in: project) == 1999)
    }

    @Test func trimLeftOfTheFirstClipClosesUp() {
        var project = Fixture.threeSegments
        #expect(trim(1, start: 300, duration: 900).apply(to: &project))
        #expect(!project.segments.contains { $0.isGap })
        #expect(TimelineMath.segmentStart(Fixture.id(2), in: project) == 900)
        #expect(TimelineMath.segmentStart(Fixture.id(3), in: project) == 1500)
        #expect(TimelineMath.outputDuration(project) == 2700)
    }

    @Test func trimLeftAfterAClipOpensAGapAndLaterSegmentsStay() {
        var project = Fixture.threeSegments
        #expect(ProjectCommand.trimSegment(id: Fixture.id(3),
                                           sourceRange: TickRange(start: 1500, duration: 900),
                                           newGapIDs: [Fixture.id(90), Fixture.id(91)])
            .apply(to: &project))
        #expect(project.segments[2] == .gap(GapSegment(id: Fixture.id(90), duration: 300)))
        #expect(TimelineMath.segmentStart(Fixture.id(3), in: project) == 2100)
        #expect(TimelineMath.outputDuration(project) == 3000)
    }

    // MARK: Limits

    @Test func rangesAtTheSourceLimitsAreAccepted() {
        var project = Fixture.threeSegments
        let minimum = ProjectCommand.minimumSegmentDuration(in: project)
        #expect(trim(3, start: 1200, duration: 1800).apply(to: &project))    // to source end
        #expect(trim(1, start: 0, duration: minimum).apply(to: &project))    // one frame
        #expect(sourceRange(3, in: project)?.end == Fixture.source.duration)
        #expect(sourceRange(1, in: project) == TickRange(start: 0, duration: minimum))
    }

    @Test(arguments: [
        TickRange(start: -1, duration: 1201),     // before source start
        TickRange(start: 1200, duration: 1801),   // past source end
        TickRange(start: 0, duration: 19),        // under one frame at 30 fps
        TickRange(start: 0, duration: 0),
        TickRange(start: 600, duration: -100),
    ])
    func invalidRangesAreRefused(range: TickRange) {
        var project = Fixture.threeSegments
        let segment = range.start == 1200 ? 3 : 1
        #expect(!ProjectCommand.trimSegment(id: Fixture.id(segment), sourceRange: range)
            .apply(to: &project))
        #expect(project == Fixture.threeSegments)
    }

    @Test func stillMissingSegmentAndNoSourceAreRefused() {
        var project = Fixture.threeSegments
        #expect(!trim(2, start: 0, duration: 600).apply(to: &project))
        #expect(!trim(99, start: 0, duration: 600).apply(to: &project))
        #expect(project == Fixture.threeSegments)
        project.source = nil
        let sourceless = project
        #expect(!trim(1, start: 0, duration: 600).apply(to: &project))
        #expect(project == sourceless)
    }

    @Test func minimumDurationIsOneFrameRoundedUp() {
        var project = Fixture.threeSegments
        #expect(ProjectCommand.minimumSegmentDuration(in: project) == 20)
        project.output.frameRate = 29.97
        #expect(ProjectCommand.minimumSegmentDuration(in: project) == 21)
        project.output.frameRate = 0
        #expect(ProjectCommand.minimumSegmentDuration(in: project) == 20)
    }

    @Test func actionName() {
        #expect(trim(1, start: 0, duration: 600).actionName == "Trim Segment")
    }
}

@MainActor
struct TrimCommandStoreTests {
    private func makeStore(_ project: Project) -> (ProjectStore, UndoManager) {
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func trim(_ n: Int, start: Tick, duration: Tick) -> ProjectCommand {
        .trimSegment(id: Fixture.id(n), sourceRange: TickRange(start: start, duration: duration))
    }

    @Test func undoRestoresIdenticalProjectAndRedoes() {
        let original = Fixture.single
        let (store, undo) = makeStore(original)
        #expect(store.perform(trim(1, start: 600, duration: 1500)))
        let edited = store.project
        #expect(undo.undoActionName == "Trim Segment")
        undo.undo()
        #expect(store.project == original)
        undo.redo()
        #expect(store.project == edited)
    }

    @Test func gestureOfSeveralTrimsIsOneUndoStep() {
        let original = Fixture.threeSegments
        let (store, undo) = makeStore(original)
        store.beginGesture(named: "Trim Segment")
        #expect(store.perform(trim(3, start: 1100, duration: 1300)))
        #expect(store.perform(trim(3, start: 1000, duration: 1400)))
        #expect(store.perform(trim(3, start: 900, duration: 1500)))
        store.endGesture()
        let edited = store.project
        #expect(undo.undoActionName == "Trim Segment")
        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project == edited)
    }
}
