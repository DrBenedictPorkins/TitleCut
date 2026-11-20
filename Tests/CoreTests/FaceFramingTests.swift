import Foundation
import Testing
@testable import TitleCutCore

struct FaceFramingTests {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let vertical = CGSize(width: 1080, height: 1920)

    @Test func framingCentresTheFaceAndStaysOnThePicture() throws {
        // A 9:16 frame shows 0.316 of a 16:9 picture's width.
        let centred = try #require(FaceFraming.framing(centering: 0.5, sourceSize: landscape,
                                                       renderSize: vertical))
        #expect(abs(centred - 0.5) < 1e-9)
        let left = try #require(FaceFraming.framing(centering: 0.3, sourceSize: landscape,
                                                    renderSize: vertical))
        // The visible part starts at framing x (1 - width) and is centred on 0.3.
        let width = (1080.0 / 1920) / (1920.0 / 1080)
        #expect(abs(left * (1 - width) + width / 2 - 0.3) < 1e-9)
        #expect(FaceFraming.framing(centering: 0.02, sourceSize: landscape,
                                    renderSize: vertical) == 0)
        #expect(FaceFraming.framing(centering: 0.99, sourceSize: landscape,
                                    renderSize: vertical) == 1)
        // A frame as wide as the source crops nothing at the sides.
        #expect(FaceFraming.framing(centering: 0.3, sourceSize: landscape,
                                    renderSize: landscape) == nil)
    }

    /// Samples every 150 ticks (0.25 s) from 0 with the given positions.
    private func samples(_ xs: [Double?]) -> [(time: Tick, x: Double?)] {
        xs.enumerated().map { (Tick($0.offset) * 150, $0.element) }
    }

    @Test func aFaceThatStaysPutMakesOnePart() {
        let parts = FaceFraming.parts(samples([0.5, 0.52, nil, 0.49, 0.6, 0.51]), start: 0,
                                      threshold: 0.08)
        #expect(parts.count == 1)
        #expect(parts[0].sourceStart == 0)
        #expect(parts[0].x == 0.51)
    }

    @Test func aFaceThatSettlesElsewhereForASecondSplits() {
        // At 0.3 for 2 s, then at 0.7 from 2 s (sample 8) on.
        let xs: [Double?] = Array(repeating: 0.3, count: 8) + Array(repeating: 0.7, count: 8)
        let parts = FaceFraming.parts(samples(xs), start: 0, threshold: 0.08)
        #expect(parts.map(\.sourceStart) == [0, 1200])
        #expect(parts.map(\.x) == [0.3, 0.7])
    }

    @Test func aBriefLookAwayDoesNotSplit() {
        // Away for 0.75 s (3 samples), then back.
        let xs: [Double?] = Array(repeating: 0.3, count: 8) + [0.7, 0.7, 0.7]
            + Array(repeating: 0.3, count: 8)
        let parts = FaceFraming.parts(samples(xs), start: 0, threshold: 0.08)
        #expect(parts.count == 1)
        #expect(parts[0].x == 0.3)
    }

    @Test func aMoveRightAfterTheStartReplacesThePosition() {
        // At 0.3 only briefly, then 0.7: no part shorter than the hold.
        let xs: [Double?] = [0.3, 0.3] + Array(repeating: 0.7, count: 10)
        let parts = FaceFraming.parts(samples(xs), start: 0, threshold: 0.08)
        #expect(parts.map(\.sourceStart) == [0])
        #expect(parts[0].x == 0.7)
    }

    @Test func aCutMovesBackToTheFirstFrameShowingTheMove() async {
        // 30 fps, 20 ticks a frame. Samples at 1125 (old) and 1275 (new);
        // the face moved at frame 60, 1200 ticks.
        var asked: [Tick] = []
        let cut = await FaceFraming.firstFrame(after: 1125, upTo: 1275, frameRate: 30) {
            asked.append($0)
            return $0 >= 1200
        }
        #expect(cut == 1200)
        // Halving 7 frames takes 3 looks, each in the middle of a frame.
        #expect(asked.count == 3)
        #expect(asked.allSatisfy { $0 % 20 == 10 })
        // Adjacent frames: nothing to look at.
        let none = await FaceFraming.firstFrame(after: 1190, upTo: 1210, frameRate: 30) { _ in
            Issue.record("No frame lies between")
            return true
        }
        #expect(none == 1200)
        // Unknown rate keeps the sample's time.
        #expect(await FaceFraming.firstFrame(after: 1125, upTo: 1275, frameRate: 0) { _ in true }
                == 1275)
    }

    @Test func samplesSpreadAcrossTheClip() {
        // Every 0.25 s (150 ticks), centred in each step.
        #expect(FaceFraming.sampleTimes(in: TickRange(start: 600, duration: 600))
                == [675, 825, 975, 1125])
        #expect(FaceFraming.sampleTimes(in: TickRange(start: 0, duration: 100)) == [50])
        #expect(FaceFraming.sampleTimes(in: TickRange(start: 0, duration: 600 * 120)).count
                == FaceFraming.maximumSamples)
    }

    @MainActor @Test func commandsSplitAndFrameEachPartAsOneUndoStep() throws {
        // v1 src [0,600) | v2 src [1200,2400) moved after it, at output 600.
        let project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        Fixture.video(2, start: 1200, duration: 1200)],
                                       titles: [Fixture.title(10, segment: 2, offset: 900)])
        typealias Part = FaceFraming.Part
        let plan: [UUID: [Part]] = [
            Fixture.id(1): [Part(sourceStart: 0, framing: 0.5)],           // unchanged
            Fixture.id(2): [Part(sourceStart: 1200, framing: 0.2),
                            Part(sourceStart: 1800, framing: 0.8)],
        ]
        let commands = FaceFraming.commands(plan, in: project, makeID: { Fixture.id(60) })
        #expect(commands == [
            .splitSegment(atOutputTime: 1200, newSegmentID: Fixture.id(60)),
            .setSegmentFraming(id: Fixture.id(2), framing: 0.2),
            .setSegmentFraming(id: Fixture.id(60), framing: 0.8),
        ])

        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(commands, named: "Frame Faces"))
        #expect(undo.undoActionName == "Frame Faces")
        let framings = store.project.segments.map { segment -> Double? in
            if case .video(let video) = segment { video.framing } else { nil }
        }
        #expect(framings == [nil, 0.2, 0.8])
        // The title at 2.5 s into v2 moved to the second part with its footage.
        #expect(store.project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(60),
                                                             offset: 300))
        undo.undo()
        #expect(store.project == project)
    }
}
