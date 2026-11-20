import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// Per-clip framing inside a narrower output frame.
struct FramingTests {
    /// 16x9: left half red, right half blue.
    private var halves: CIImage {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 9))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 8, y: 0, width: 8, height: 9))
        return blue.composited(over: red)
    }

    private func centre(framing: Double) -> (r: Double, g: Double, b: Double) {
        let frame = FrameRenderer.render(source: halves, preferredTransform: .identity,
                                         renderSize: CGSize(width: 9, height: 16),
                                         frame: ClipFraming(x: framing))
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(frame, from: frame.extent)!)
        return pixels.rgb(x: 4, y: 8)
    }

    @Test func framingSlidesTheCropAcrossThePicture() {
        // The 9-wide frame over a 16-wide picture: 0 shows the left (red), 1 the right (blue).
        #expect(centre(framing: 0).r > 200 && centre(framing: 0).b < 50)
        #expect(centre(framing: 1).b > 200 && centre(framing: 1).r < 50)
    }

    @MainActor @Test func reframingIsOneUndoStepAndClamps() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.beginGesture(named: "Reframe Clip")
        for framing in [0.4, 0.2, -0.3] {
            store.perform(.setSegmentFraming(id: Fixture.id(1), framing: framing))
        }
        store.endGesture()
        guard case .video(let video) = store.project.segments[0] else {
            Issue.record("not video"); return
        }
        #expect(video.framing == 0)
        #expect(undo.undoActionName == "Reframe Clip")
        undo.undo()
        #expect(store.project == original)
    }

    @Test func gapsCannotBeReframed() {
        var project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        MoveFixture.gap(2, duration: 300)])
        #expect(!ProjectCommand.setSegmentFraming(id: Fixture.id(2), framing: 0.2)
            .apply(to: &project))
    }

    @Test func splitHalvesKeepTheFraming() {
        var project = Fixture.single
        ProjectCommand.setSegmentFraming(id: Fixture.id(1), framing: 0.25).apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 1500, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        let framings = project.segments.compactMap { segment -> Double? in
            if case .video(let video) = segment { video.framing } else { nil }
        }
        #expect(framings == [0.25, 0.25])
    }

    @Test func segmentsSavedWithoutFramingStillLoad() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","sourceRange":{"start":0,"duration":600}}"#
        let video = try JSONDecoder().decode(VideoSegment.self, from: Data(json.utf8))
        #expect(video.framing == nil)
    }
}
