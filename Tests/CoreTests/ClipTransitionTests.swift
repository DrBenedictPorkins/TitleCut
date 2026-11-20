import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

private let dip = ClipTransition(kind: .dipToBlack, duration: 600)
private let crossfade = ClipTransition(kind: .crossfade, duration: 600)

/// v1 [0,600) src 0 | v2 [600,1200) src 600 | v3 [1200,1800) src 1200.
private var clips: Project { MoveFixture.clips }

private func segment(_ n: Int, in project: Project) -> Segment? {
    project.segments.first { $0.id == Fixture.id(n) }
}

struct ClipTransitionCommandTests {
    @Test func setsAndRemovesATransitionAtACut() {
        var project = clips
        #expect(ProjectCommand.setClipTransition(at: .before(Fixture.id(2)), transition: crossfade)
            .apply(to: &project))
        #expect(segment(2, in: project)?.transitionIn == crossfade)
        #expect(TransitionPoint.before(Fixture.id(2)).transition(in: project) == crossfade)
        #expect(ProjectCommand.setClipTransition(at: .before(Fixture.id(2)), transition: nil)
            .apply(to: &project))
        #expect(project == clips)
    }

    @Test func refusesCrossfadesAtTheStartAndEnd() {
        var project = clips
        #expect(!ProjectCommand.setClipTransition(at: .before(Fixture.id(1)), transition: crossfade)
            .apply(to: &project))
        #expect(!ProjectCommand.setClipTransition(at: .end, transition: crossfade)
            .apply(to: &project))
        #expect(ProjectCommand.setClipTransition(at: .before(Fixture.id(1)), transition: dip)
            .apply(to: &project))
        #expect(ProjectCommand.setClipTransition(at: .end, transition: dip).apply(to: &project))
        #expect(segment(3, in: project)?.transitionOut == dip)
    }

    @Test func refusesBadDurationsMissingSegmentsAndNoChange() {
        var project = clips
        for duration in [ClipTransition.minimumDuration - 1, ClipTransition.maximumDuration + 1] {
            #expect(!ProjectCommand.setClipTransition(
                at: .before(Fixture.id(2)),
                transition: ClipTransition(kind: .dipToWhite, duration: duration))
                .apply(to: &project))
        }
        #expect(!ProjectCommand.setClipTransition(at: .before(Fixture.id(99)), transition: dip)
            .apply(to: &project))
        #expect(!ProjectCommand.setClipTransition(at: .before(Fixture.id(2)), transition: nil)
            .apply(to: &project))
        #expect(project == clips)
    }

    @Test func splittingKeepsTheTransitionsAtTheOuterEdges() {
        var project = clips
        project.segments[1].transitionIn = dip
        project.segments[2].transitionOut = dip
        #expect(ProjectCommand.splitSegment(atOutputTime: 900, newSegmentID: Fixture.id(20))
            .apply(to: &project))
        #expect(segment(2, in: project)?.transitionIn == dip)
        #expect(segment(20, in: project)?.transitionIn == nil)
        #expect(ProjectCommand.splitSegment(atOutputTime: 1500, newSegmentID: Fixture.id(21))
            .apply(to: &project))
        #expect(segment(3, in: project)?.transitionOut == nil)
        #expect(segment(21, in: project)?.transitionOut == dip)
    }

    @Test func theEndTransitionStaysAtTheEnd() {
        var project = clips
        project.segments[2].transitionOut = dip
        // The last clip moves to the front: v2 is last now.
        #expect(ProjectCommand.moveSegment(id: Fixture.id(3), toOutputStart: 0,
                                           newGapIDs: [Fixture.id(30), Fixture.id(31)])
            .apply(to: &project))
        #expect(project.segments.last?.transitionOut == dip)
        #expect(project.segments.dropLast().allSatisfy { $0.transitionOut == nil })
        #expect(ProjectCommand.deleteSegment(id: project.segments.last!.id).apply(to: &project))
        #expect(project.segments.last?.transitionOut == dip)
    }

    @Test func aFreezeAtAClipStartTakesItsTransition() {
        var project = clips
        project.segments[1].transitionIn = crossfade
        let still = StillImage(id: Fixture.id(900), fileName: "s.png", capturedAt: 600,
                               pixelSize: CGSize(width: 640, height: 360))
        #expect(ProjectCommand.insertStill(still, segmentID: Fixture.id(40),
                                           splitID: Fixture.id(41), atOutputTime: 600,
                                           duration: 300).apply(to: &project))
        #expect(segment(40, in: project)?.transitionIn == crossfade)
        #expect(segment(2, in: project)?.transitionIn == nil)
    }

    @Test func pointsFindTheirTimes() {
        let project = clips
        #expect(TransitionPoint.at(0, in: project) == .before(Fixture.id(1)))
        #expect(TransitionPoint.at(600, in: project) == .before(Fixture.id(2)))
        #expect(TransitionPoint.at(1800, in: project) == .end)
        #expect(TransitionPoint.at(700, in: project) == nil)
        #expect(TransitionPoint.end.time(in: project) == 1800)
        #expect(TransitionPoint.before(Fixture.id(1)).isEdge(in: project))
        #expect(!TransitionPoint.before(Fixture.id(3)).isEdge(in: project))
        #expect(ClipTransitionKind.dipToBlack.name(at: .before(Fixture.id(1)), in: project)
            == "Fade from Black")
        #expect(ClipTransitionKind.dipToWhite.name(at: .end, in: project) == "Fade to White")
    }

    @Test func transitionsSurviveSavingAndOlderFilesReadWithout() throws {
        var project = clips
        project.segments[0].transitionIn = dip
        project.segments[1].transitionIn = crossfade
        project.segments[2].transitionOut = ClipTransition(kind: .dipToWhite, duration: 300)
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
        let old = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(clips))
        #expect(old.segments.allSatisfy { $0.transitionIn == nil && $0.transitionOut == nil })
    }

    @MainActor @Test func oneUndoStepNamedForTheChange() {
        let store = ProjectStore(project: clips)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(.setClipTransition(at: .before(Fixture.id(2)), transition: dip)))
        #expect(undo.undoActionName == "Set Transition")
        undo.undo()
        #expect(store.project == clips)
    }
}

struct ClipTransitionPlanTests {
    @Test func cutsPlayHalfEachSideAndEdgesOneSide() {
        var project = clips
        project.segments[0].transitionIn = ClipTransition(kind: .dipToBlack, duration: 200)
        project.segments[1].transitionIn = ClipTransition(kind: .crossfade, duration: 200)
        project.segments[2].transitionOut = ClipTransition(kind: .dipToWhite, duration: 200)
        #expect(ClipTransitionPlan.windows(project) == [
            .init(time: 0, index: 0, kind: .dipToBlack, before: 0, after: 200, isEdge: true),
            .init(time: 600, index: 1, kind: .crossfade, before: 100, after: 100, isEdge: false),
            .init(time: 1800, index: 3, kind: .dipToWhite, before: 200, after: 0, isEdge: true),
        ])
    }

    @Test func eachSideIsCutToHalfTheSegmentThere() {
        var project = MoveFixture.with([Fixture.video(1, start: 0, duration: 100),
                                        Fixture.video(2, start: 600, duration: 1000)])
        project.segments[0].transitionIn = ClipTransition(kind: .dipToBlack, duration: 3000)
        project.segments[1].transitionIn = ClipTransition(kind: .crossfade, duration: 3000)
        project.segments[1].transitionOut = ClipTransition(kind: .dipToBlack, duration: 3000)
        #expect(ClipTransitionPlan.windows(project) == [
            .init(time: 0, index: 0, kind: .dipToBlack, before: 0, after: 50, isEdge: true),
            .init(time: 100, index: 1, kind: .crossfade, before: 50, after: 500, isEdge: false),
            .init(time: 1100, index: 2, kind: .dipToBlack, before: 500, after: 0, isEdge: true),
        ])
    }
}

/// Clip transitions through `CompositionBuilder` and the compositor.
@Suite(.serialized)
struct ClipTransitionRenderTests {
    private func project(_ segments: [Segment], url: URL) async throws -> Project {
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        project.segments = segments
        return project
    }

    private func centre(_ pixels: RenderFixture.Pixels) -> (r: Double, g: Double, b: Double) {
        pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
    }

    private func expectClose(_ a: (r: Double, g: Double, b: Double),
                             _ b: (r: Double, g: Double, b: Double), within: Double = 4,
                             _ note: String) {
        #expect(abs(a.r - b.r) <= within && abs(a.g - b.g) <= within
                && abs(a.b - b.b) <= within, "\(note): \(a) vs \(b)")
    }

    private func mix(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double),
                     _ amount: Double) -> (r: Double, g: Double, b: Double) {
        (a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
    }

    @Test func noTransitionsKeepOneInstructionPerSegment() async throws {
        let url = try await RenderFixture.numbered.value
        let project = try await project([Fixture.video(1, start: 0, duration: 600),
                                         Fixture.video(2, start: 1200, duration: 600)], url: url)
        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        #expect(built.videoComposition?.instructions.count == 2)
        #expect(built.composition.tracks(withMediaType: .video).count == 1)
    }

    @Test func dipsAndFadesReachTheirColourAtTheCut() async throws {
        let url = try await RenderFixture.numbered.value
        // src [0,1 s) then src [2 s,4 s); fade from black 0.5 s, dip to
        // white 1 s at 1 s, fade to black 0.5 s.
        var segments = [Fixture.video(1, start: 0, duration: 600),
                        Fixture.video(2, start: 1200, duration: 1200)]
        segments[0].transitionIn = ClipTransition(kind: .dipToBlack, duration: 300)
        segments[1].transitionIn = ClipTransition(kind: .dipToWhite, duration: 600)
        segments[1].transitionOut = ClipTransition(kind: .dipToBlack, duration: 300)
        let project = try await project(segments, url: url)
        let black = (r: 0.0, g: 0.0, b: 0.0), white = (r: 255.0, g: 255.0, b: 255.0)
        expectClose(centre(try await RenderFixture.frame(of: project, from: url, at: 0)), black,
                    "start")
        expectClose(centre(try await RenderFixture.frame(of: project, from: url, at: 1)), white,
                    "cut")
        // Between the dip and the end fade the clip is untouched: src 3 s.
        let middle = centre(try await RenderFixture.frame(of: project, from: url, at: 2))
        expectClose(middle, centre(try await RenderFixture.directFrame(90, from: url)), "middle")
        // Frame 83 (2.767 s) is 0.533 into the end fade [2.5 s, 3 s): src 3.767 s.
        let fading = centre(try await RenderFixture.frame(of: project, from: url, at: 83.0 / 30))
        let source = centre(try await RenderFixture.directFrame(113, from: url))
        expectClose(fading, mix(source, black, 1.6 / 3), within: 6, "end fade")
    }

    @Test func crossfadesMixFramesFromPastEachCut() async throws {
        let url = try await RenderFixture.numbered.value
        // src [0,1 s) then src [3 s,4 s), crossfade 1 s at 1 s.
        var segments = [Fixture.video(1, start: 0, duration: 600),
                        Fixture.video(2, start: 1800, duration: 600)]
        segments[1].transitionIn = crossfade
        let project = try await project(segments, url: url)
        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        #expect(Ticks.from(built.composition.duration) == 1200)

        // At the cut, half of each: clip 1 run on to src 1 s, clip 2 at src 3 s.
        let cut = centre(try await RenderFixture.frame(of: project, from: url, at: 1))
        let outgoing = centre(try await RenderFixture.directFrame(30, from: url))
        let incoming = centre(try await RenderFixture.directFrame(90, from: url))
        expectClose(cut, mix(outgoing, incoming, 0.5), within: 6, "cut")
        // Before the cut, clip 2 is borrowed from before its start: frame 23
        // (0.767 s) is 0.533 through [0.5 s, 1 s), so a 0.267 share of src
        // 2.767 s (frame 83) over src 0.767 s.
        let before = centre(try await RenderFixture.frame(of: project, from: url, at: 23.0 / 30))
        expectClose(before, mix(centre(try await RenderFixture.directFrame(23, from: url)),
                                centre(try await RenderFixture.directFrame(83, from: url)),
                                0.8 / 3), within: 6, "before the cut")
    }

    @Test func aCrossfadeHoldsTheSourcesFirstFrameWhereItRunsOut() async throws {
        let url = try await RenderFixture.numbered.value
        // src [1 s,2 s) then src [0,1 s): clip 2 has nothing before its start.
        var segments = [Fixture.video(1, start: 600, duration: 600),
                        Fixture.video(2, start: 0, duration: 600)]
        segments[1].transitionIn = crossfade
        let project = try await project(segments, url: url)
        let frame = centre(try await RenderFixture.frame(of: project, from: url, at: 23.0 / 30))
        expectClose(frame, mix(centre(try await RenderFixture.directFrame(53, from: url)),
                               centre(try await RenderFixture.directFrame(0, from: url)),
                               0.8 / 3), within: 6, "held frame")
    }
}
