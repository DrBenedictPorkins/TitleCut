import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// Title cards: `insertCard`, `setCardDuration`, `setCardColor`, and how
/// cards save, split, move and render.
@MainActor
struct CardSegmentTests {
    private let red = RGBA(red: 0.8, green: 0.1, blue: 0.1)

    private func card(_ n: Int, duration: Tick = 1800, color: RGBA = RGBA(red: 0, green: 0, blue: 0))
        -> CardSegment {
        CardSegment(id: Fixture.id(n), duration: duration, color: color)
    }

    private func insert(_ card: CardSegment, at time: Tick, in project: inout Project) -> Bool {
        ProjectCommand.insertCard(card, splitID: Fixture.id(99), atOutputTime: time)
            .apply(to: &project)
    }

    @Test func insideAClipSplitsItAndPushesLaterTitles() {
        var project = Fixture.single
        #expect(insert(card(50), at: 900, in: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(50), Fixture.id(99)])
        #expect(project.segments.map(\.duration) == [900, 1800, 2100])
        #expect(TimelineMath.outputDuration(project) == 4800)
        // Title 11 was at 1200 s-ticks; it moves after the card with its footage.
        let starts = project.titles.map { TimelineMath.titleOutputRange($0, in: project)?.start }
        #expect(starts == [300, 3000, 4200])
    }

    @Test func atACutItTakesTheCutsTransition() {
        var project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        Fixture.video(2, start: 600, duration: 600)])
        let dip = ClipTransition(kind: .dipToBlack, duration: 300)
        #expect(ProjectCommand.setClipTransition(at: .before(Fixture.id(2)), transition: dip)
            .apply(to: &project))
        #expect(insert(card(50), at: 600, in: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(50), Fixture.id(2)])
        #expect(project.segments[1].transitionIn == dip)
        #expect(project.segments[2].transitionIn == nil)
    }

    @Test func atTheEndItIsAppendedAndTakesTheEndTransition() {
        var project = Fixture.single
        let fade = ClipTransition(kind: .dipToBlack, duration: 600)
        #expect(ProjectCommand.setClipTransition(at: .end, transition: fade).apply(to: &project))
        #expect(insert(card(50, color: red), at: 3000, in: &project))
        #expect(project.segments.last == .card(CardSegment(id: Fixture.id(50), duration: 1800,
                                                           color: red, transitionOut: fade)))
        #expect(project.segments[0].transitionOut == nil)
    }

    @Test func insideAGapItSplitsTheGap() {
        var project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        MoveFixture.gap(5, duration: 900),
                                        Fixture.video(2, start: 600, duration: 600)])
        project.titles = [Fixture.title(10, segment: 5, offset: 600)]
        #expect(insert(card(50), at: 900, in: &project))
        #expect(project.segments.map(\.id)
            == [Fixture.id(1), Fixture.id(5), Fixture.id(50), Fixture.id(99), Fixture.id(2)])
        #expect(project.segments.map(\.duration) == [600, 300, 1800, 600, 600])
        // The title after the card keeps its place in the rest of the gap.
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(99), offset: 300))
    }

    @Test func refusedOnAnEmptyTimelineOrWithTakenIDs() {
        var empty = Fixture.single
        empty.segments = []
        empty.titles = []
        #expect(!insert(card(50), at: 0, in: &empty))
        var project = Fixture.single
        #expect(!insert(card(1), at: 0, in: &project))
        #expect(!insert(card(50, duration: 0), at: 0, in: &project))
    }

    @Test func lengthAndColourChangeAndUndo() {
        var project = Fixture.single
        #expect(insert(card(50), at: 0, in: &project))
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        #expect(store.perform(.setCardDuration(id: Fixture.id(50), duration: 900)))
        #expect(undo.undoActionName == "Change Card Length")
        #expect(store.perform(.setCardColor(id: Fixture.id(50), color: red)))
        #expect(undo.undoActionName == "Change Card Colour")
        #expect(store.project.segments[0] == .card(card(50, duration: 900, color: red)))
        // Not for other segments, and not shorter than a frame.
        #expect(!store.perform(.setCardDuration(id: Fixture.id(1), duration: 900)))
        #expect(!store.perform(.setCardDuration(id: Fixture.id(50), duration: 0)))

        undo.undo()
        undo.undo()
        #expect(store.project == project)
    }

    @Test func savesSplitsMovesAndDeletes() throws {
        var project = Fixture.single
        #expect(insert(card(50, color: red), at: 0, in: &project))
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
        #expect(String(decoding: data, as: UTF8.self).contains("\"card\""))

        var split = project
        #expect(ProjectCommand.splitSegment(atOutputTime: 600, newSegmentID: Fixture.id(60))
            .apply(to: &split))
        #expect(split.segments.prefix(2).map(\.duration) == [600, 1200])
        if case .card(let second) = split.segments[1] { #expect(second.color == red) }

        var moved = project
        #expect(ProjectCommand.moveSegment(id: Fixture.id(50), toOutputStart: 4800)
            .apply(to: &moved))
        #expect(moved.segments.last?.id == Fixture.id(50))

        var deleted = project
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(50)).apply(to: &deleted))
        #expect(deleted.segments.map(\.id) == [Fixture.id(1)])
    }

    @Test func rendersItsColour() throws {
        let size = CGSize(width: 4, height: 4)
        let image = FrameRenderer.solid(red, renderSize: size)
        #expect(image.extent == CGRect(origin: .zero, size: size))
        let context = CIContext(options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                       colorSpace: nil)
        #expect(pixel == [204, 26, 26, 255])
    }
}

@Suite(.serialized)
struct CardRenderTests {
    @Test func aCardAtTheEndCountsInTheDurationAndRendersItsColour() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        // src [0,1 s) | card 1 s, red
        project.segments = [Fixture.video(1, start: 0, duration: 600),
                            .card(CardSegment(id: Fixture.id(50), duration: 600,
                                              color: RGBA(red: 0.8, green: 0.1, blue: 0.1)))]

        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        #expect(Ticks.from(built.composition.duration) == 1200)

        let pixels = try await RenderFixture.frame(of: project, from: url, at: 1.5)
        let centre = pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
        #expect(abs(centre.r - 204) < 12 && centre.g < 40 && centre.b < 40)
    }
}
