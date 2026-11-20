import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

/// Gaps, moving clips and gap-aware trims (PLAN §12, "Moving clips and gaps").
enum MoveFixture {
    static func gap(_ n: Int, duration: Tick) -> Segment {
        .gap(GapSegment(id: Fixture.id(n), duration: duration))
    }

    /// v1 [0,600) src 0 | v2 [600,1200) src 600 | v3 [1200,1800) src 1200.
    /// Title 10 on v2 at 100.
    static var clips: Project {
        Project(id: Fixture.projectID, source: Fixture.source,
                segments: [Fixture.video(1, start: 0, duration: 600),
                           Fixture.video(2, start: 600, duration: 600),
                           Fixture.video(3, start: 1200, duration: 600)],
                titles: [Fixture.title(10, segment: 2, offset: 100)])
    }

    static func with(_ segments: [Segment], titles: [Title] = []) -> Project {
        Project(id: Fixture.projectID, source: Fixture.source, segments: segments, titles: titles)
    }

    static let newGaps = [Fixture.id(91), Fixture.id(92)]

    static func move(_ n: Int, to start: Tick) -> ProjectCommand {
        .moveSegment(id: Fixture.id(n), toOutputStart: start, newGapIDs: newGaps)
    }

    static func trim(_ n: Int, start: Tick, duration: Tick) -> ProjectCommand {
        .trimSegment(id: Fixture.id(n), sourceRange: TickRange(start: start, duration: duration),
                     newGapIDs: newGaps)
    }

    static func start(_ n: Int, in project: Project) -> Tick? {
        TimelineMath.segmentStart(Fixture.id(n), in: project)
    }
}

struct GapModelTests {
    typealias M = MoveFixture

    @Test func gapExactJSONShapeAndRoundTrip() throws {
        let segment = M.gap(5, duration: 450)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(segment), encoding: .utf8))
        #expect(json == #"{"gap":{"duration":450,"id":"00000000-0000-0000-0000-000000000005"}}"#)
        #expect(try JSONDecoder().decode(Segment.self, from: Data(json.utf8)) == segment)

        let project = M.with([M.gap(5, duration: 450), Fixture.video(1, start: 0, duration: 600)],
                             titles: [Fixture.title(10, segment: 5, offset: 30)])
        let data = try ProjectFile.encode(project)
        #expect(try ProjectFile.decode(data) == project)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\"_0\""))
        #expect(text.contains("\"formatVersion\" : 1"))
    }

    @Test func splitInsideAGapIsRefused() {
        var project = M.with([M.gap(5, duration: 600), Fixture.video(1, start: 0, duration: 600)])
        #expect(!ProjectCommand.splitSegment(atOutputTime: 300, newSegmentID: Fixture.id(50))
            .apply(to: &project))
    }

    @Test func deletingAGapClosesIt() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600)],
                             titles: [Fixture.title(10, segment: 5, offset: 0)])
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(5)).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(2)])
        #expect(M.start(2, in: project) == 600)
        #expect(project.titles.isEmpty)
    }

    @Test func deletingAClipBetweenGapsMergesThem() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600), M.gap(6, duration: 200),
                              Fixture.video(3, start: 1200, duration: 600)],
                             titles: [Fixture.title(10, segment: 6, offset: 50)])
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(2)).apply(to: &project))
        #expect(project.segments == [Fixture.video(1, start: 0, duration: 600),
                                     M.gap(5, duration: 500),
                                     Fixture.video(3, start: 1200, duration: 600)])
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 350))
    }

    @Test func deletingTheLastClipDropsTheTrailingGap() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600)])
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(2)).apply(to: &project))
        #expect(project.segments == [Fixture.video(1, start: 0, duration: 600)])
    }

    @Test func titlesCanAnchorToAGap() {
        var project = M.with([M.gap(5, duration: 600), Fixture.video(1, start: 0, duration: 600)])
        #expect(ProjectCommand.addTitle(id: Fixture.id(20), text: "Intro", atOutputTime: 100,
                                        style: TitleCommandFixture.style(801))
            .apply(to: &project))
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 100))
        #expect(TimelineMath.sourceTime(100, in: project) == nil)
    }

    @Test func snapPicksTheNearestPointWithinTolerance() {
        #expect(TimelineMath.snap([100, 700], to: [0, 690, 1000], tolerance: 20)?.shift == -10)
        #expect(TimelineMath.snap([100, 700], to: [0, 690, 1000], tolerance: 20)?.point == 690)
        #expect(TimelineMath.snap([100], to: [0, 1000], tolerance: 20) == nil)
        #expect(TimelineMath.clipEdges(M.with([M.gap(5, duration: 300),
                                              Fixture.video(1, start: 0, duration: 600),
                                              Fixture.video(2, start: 0, duration: 600)]),
                                       excluding: Fixture.id(2)) == [300, 900])
    }
}

struct MoveSegmentTests {
    typealias M = MoveFixture

    @Test func movePastTheEndAppendsAndClosesUpItsPlace() {
        var project = M.clips
        #expect(M.move(1, to: 2400).apply(to: &project))
        #expect(project.segments == [Fixture.video(2, start: 600, duration: 600),
                                     Fixture.video(3, start: 1200, duration: 600),
                                     Fixture.video(1, start: 0, duration: 600)])
        #expect(TimelineMath.outputDuration(project) == 1800)
    }

    @Test func moveOntoAClipGoesToItsNearerEdgeAndPushes() {
        var project = M.clips
        // 700 is near v2's start: v3 goes before v2.
        #expect(M.move(3, to: 700).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(3), Fixture.id(2)])
        #expect(M.start(2, in: project) == 1200)

        project = M.clips
        // Without v1, 400 is past v2's middle: v1 goes after v2; its old place closes.
        #expect(M.move(1, to: 400).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(2), Fixture.id(1), Fixture.id(3)])
        #expect(M.start(3, in: project) == 1200)
        #expect(!project.segments.contains { $0.isGap })
    }

    @Test func draggingRightSwapsOnceTheRightEdgePassesTheNextMiddle() {
        // v2 moved right by d sits at 600 + d; without it, v3 spans 600..1200.
        for (d, order) in [(Tick(200), [1, 2, 3]), (Tick(400), [1, 3, 2])] {
            var project = M.clips
            #expect(M.move(2, to: 600 + d).apply(to: &project))
            #expect(project.segments.map(\.id) == order.map(Fixture.id))
        }
    }

    @Test func moveIntoAGapTakesTheSpace() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 1200),
                              Fixture.video(2, start: 600, duration: 600)])
        #expect(M.move(2, to: 900).apply(to: &project))
        #expect(project.segments == [Fixture.video(1, start: 0, duration: 600),
                                     M.gap(5, duration: 300),
                                     Fixture.video(2, start: 600, duration: 600)])
    }

    @Test func moveIntoAGapTooSmallPushesByTheOverflow() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600),
                              Fixture.video(3, start: 1200, duration: 600)])
        #expect(M.move(3, to: 700).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(5), Fixture.id(3),
                                               Fixture.id(2)])
        #expect(M.start(3, in: project) == 700)
        #expect(M.start(2, in: project) == 1300)
    }

    @Test func adjacentGapsMergeAndTheirTitlesKeepTheirTime() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600), M.gap(6, duration: 300),
                              Fixture.video(3, start: 1200, duration: 600)],
                             titles: [Fixture.title(10, segment: 6, offset: 50)])
        #expect(M.move(2, to: 2400).apply(to: &project))
        // 2400 is the end once v2 has left: no gap before it.
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(5), Fixture.id(3),
                                               Fixture.id(2)])
        // Lifting v2 merged the gaps; the title moved up with the close-up.
        #expect(project.segments[1] == M.gap(5, duration: 600))
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 350))
    }

    @Test func aTrailingGapIsDropped() {
        var project = M.clips
        #expect(M.move(3, to: 0).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(3), Fixture.id(1), Fixture.id(2)])
        #expect(!project.segments.contains { $0.isGap })
    }

    @Test func titlesFollowAMovedClip() {
        var project = M.clips
        #expect(M.move(2, to: 2400).apply(to: &project))
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 100))
        #expect(TimelineMath.titleOutputRange(project.titles[0], in: project)?.start == 1300)
    }

    @Test func aClipDroppedOverAGapTitleTakesTheTitle() {
        var project = M.with([M.gap(5, duration: 1200), Fixture.video(1, start: 0, duration: 600),
                              Fixture.video(2, start: 600, duration: 600)],
                             titles: [Fixture.title(10, segment: 5, offset: 100)])
        #expect(M.move(2, to: 0).apply(to: &project))
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 100))
    }

    @Test func refusals() {
        var project = M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                              Fixture.video(2, start: 600, duration: 600)])
        let original = project
        #expect(!M.move(5, to: 0).apply(to: &project))                 // a gap
        #expect(!M.move(99, to: 0).apply(to: &project))                // missing
        #expect(!ProjectCommand.moveSegment(id: Fixture.id(1), toOutputStart: 900,
                                            newGapIDs: [Fixture.id(5), Fixture.id(93)])
            .apply(to: &project))                                      // ID in use
        #expect(!ProjectCommand.moveSegment(id: Fixture.id(1), toOutputStart: 900,
                                            newGapIDs: [Fixture.id(93)])
            .apply(to: &project))                                      // too few IDs
        #expect(project == original)
        #expect(M.move(1, to: 0).actionName == "Move Segment")
    }
}

struct GapTrimTests {
    typealias M = MoveFixture

    /// v1 src [0,600) | gap 300 | v2 src [1200,1800).
    static var spaced: Project {
        M.with([Fixture.video(1, start: 0, duration: 600), M.gap(5, duration: 300),
                Fixture.video(2, start: 1200, duration: 600)],
               titles: [Fixture.title(10, segment: 5, offset: 250)])
    }

    @Test func extendingRightEatsTheGapFirst() {
        var project = Self.spaced
        #expect(M.trim(1, start: 0, duration: 800).apply(to: &project))
        #expect(project.segments[1] == M.gap(5, duration: 100))
        #expect(M.start(2, in: project) == 900)
        // The gap title at output 850 stays there, now inside the gap at 50.
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 50))
    }

    @Test func extendingRightPastTheGapPushes() {
        var project = Self.spaced
        #expect(M.trim(1, start: 0, duration: 1100).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(2)])
        #expect(M.start(2, in: project) == 1100)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(1), offset: 850))
    }

    @Test func extendingLeftEatsTheGapFirst() {
        var project = Self.spaced
        #expect(M.trim(2, start: 1000, duration: 800).apply(to: &project))
        #expect(project.segments[1] == M.gap(5, duration: 100))
        #expect(M.start(2, in: project) == 700)
        #expect(TimelineMath.outputDuration(project) == 1500)
        // Output 850 is now inside v2, at 150.
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 150))
    }

    @Test func extendingLeftPastTheGapPushes() {
        var project = Self.spaced
        #expect(M.trim(2, start: 700, duration: 1100).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(2)])
        #expect(M.start(2, in: project) == 600)
        #expect(TimelineMath.outputDuration(project) == 1700)
    }

    @Test func shrinkingWidensTheGapAndLaterClipsStay() {
        var project = Self.spaced
        #expect(M.trim(1, start: 0, duration: 400).apply(to: &project))
        #expect(project.segments[1] == M.gap(5, duration: 500))
        #expect(M.start(2, in: project) == 900)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 450))
    }

    @Test func shrinkingNextToAClipOpensAGap() {
        var project = M.clips
        #expect(M.trim(1, start: 0, duration: 400).apply(to: &project))
        #expect(project.segments[1] == M.gap(91, duration: 200))
        #expect(M.start(2, in: project) == 600)
    }

    @Test func shrinkingTheLastClipOpensNoGap() {
        var project = M.clips
        #expect(M.trim(3, start: 1200, duration: 300).apply(to: &project))
        #expect(project.segments.count == 3)
        #expect(TimelineMath.outputDuration(project) == 1500)
    }
}

@MainActor
struct MoveUndoTests {
    typealias M = MoveFixture

    private func makeStore(_ project: Project) -> (ProjectStore, UndoManager) {
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    nonisolated static let commands: [(Project, ProjectCommand)] = [
        (MoveFixture.clips, MoveFixture.move(1, to: 2400)),
        (MoveFixture.clips, MoveFixture.move(3, to: 700)),
        (GapTrimTests.spaced, MoveFixture.trim(1, start: 0, duration: 1100)),
        (GapTrimTests.spaced, MoveFixture.trim(2, start: 1000, duration: 800)),
        (GapTrimTests.spaced, .deleteSegment(id: Fixture.id(5))),
    ]

    @Test(arguments: 0..<commands.count)
    func undoRestoresTheIdenticalProject(index: Int) {
        let (original, command) = Self.commands[index]
        let (store, undo) = makeStore(original)
        #expect(store.perform(command))
        let edited = store.project
        undo.undo()
        #expect(store.project == original)
        undo.redo()
        #expect(store.project == edited)
    }

    @Test func aDragOverAClipAndBackChangesNothing() {
        let (store, undo) = makeStore(M.clips)
        store.beginGesture(named: "Move Segment")
        #expect(store.performInGesture(M.move(2, to: 1600)))
        #expect(M.start(2, in: store.project) == 1200)         // v2 went after v3
        #expect(M.start(3, in: store.project) == 600)
        #expect(store.performInGesture(M.move(2, to: 600)))
        store.endGesture()
        #expect(store.project == M.clips)
        #expect(!undo.canUndo)
    }

    @Test func replayedStepsStartFromTheGestureStart() {
        let (store, undo) = makeStore(M.clips)
        store.beginGesture(named: "Move Segment")
        for start: Tick in [700, 1300, 2400] {
            #expect(store.performInGesture(M.move(2, to: start)))
        }
        store.endGesture()
        var expected = M.clips
        M.move(2, to: 2400).apply(to: &expected)
        #expect(store.project == expected)
        #expect(undo.undoActionName == "Move Segment")
        undo.undo()
        #expect(store.project == M.clips)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project == expected)
    }

    @Test func aRefusedReplayLeavesTheLastStep() {
        let (store, _) = makeStore(M.clips)
        store.beginGesture(named: "Move Segment")
        #expect(store.performInGesture(M.move(2, to: 2400)))
        let moved = store.project
        #expect(!store.performInGesture(M.move(99, to: 0)))
        #expect(store.project == moved)
        store.endGesture()
    }

    @Test func outsideAGestureSeveralCommandsAreOneUndoStep() {
        let (store, undo) = makeStore(M.clips)
        #expect(store.performInGesture(
            M.move(1, to: 2400),
            .moveSegment(id: Fixture.id(2), toOutputStart: 3000,
                         newGapIDs: [Fixture.id(93), Fixture.id(94)])))
        #expect(undo.undoActionName == "Move Segment")
        undo.undo()
        #expect(store.project == M.clips)
        #expect(!undo.canUndo)
    }

    @Test func aDragOfSeveralMovesIsOneUndoStep() {
        let (store, undo) = makeStore(M.clips)
        store.beginGesture(named: "Move Segment")
        for start: Tick in [700, 2000] {
            #expect(store.perform(.moveSegment(id: Fixture.id(1), toOutputStart: start)))
        }
        store.endGesture()
        #expect(undo.undoActionName == "Move Segment")
        undo.undo()
        #expect(store.project == M.clips)
        #expect(!undo.canUndo)
    }
}

/// Gaps through `CompositionBuilder` and the compositor.
@Suite(.serialized)
struct GapRenderTests {
    @Test func gapsCountInTheDurationAndRenderBlack() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        // gap 1 s | src [0,1 s) | gap 1 s | src [1 s,2 s)
        project.segments = [MoveFixture.gap(5, duration: 600),
                            Fixture.video(1, start: 0, duration: 600),
                            MoveFixture.gap(6, duration: 600),
                            Fixture.video(2, start: 600, duration: 600)]

        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        #expect(Ticks.from(built.composition.duration) == 2400)

        for seconds in [0.5, 2.5] {
            let pixels = try await RenderFixture.frame(of: project, from: url, at: seconds)
            let centre = pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
            #expect(centre.r < 8 && centre.g < 8 && centre.b < 8, "\(seconds) s: \(centre)")
        }
        for (seconds, source) in [(1.0 + 0.5 / 30, 0), (3.0 + 0.5 / 30, 30)] {
            let pixels = try await RenderFixture.frame(of: project, from: url, at: seconds)
            let centre = pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
            let reference = try await RenderFixture.directFrame(source, from: url)
            let expected = reference.rgb(x: reference.width / 2, y: reference.height / 2)
            let distance = ((centre.r - expected.r) * (centre.r - expected.r)
                + (centre.g - expected.g) * (centre.g - expected.g)
                + (centre.b - expected.b) * (centre.b - expected.b)).squareRoot()
            #expect(distance <= 2, "\(seconds) s: \(centre) vs source \(source) \(expected)")
        }
    }
}
