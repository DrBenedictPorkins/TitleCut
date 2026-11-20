import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// Framing in both directions and zoom (`ClipFraming`), for whole clips and
/// split-screen halves.
struct ZoomFramingTests {
    /// 20x20: red top-left, green top-right, blue bottom-left, white
    /// bottom-right.
    private var quarters: CIImage {
        func square(_ color: CIColor, x: CGFloat, y: CGFloat) -> CIImage {
            CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: 10, height: 10))
        }
        // Core Image's origin is bottom-left.
        return square(.red, x: 0, y: 10)
            .composited(over: square(.green, x: 10, y: 10))
            .composited(over: square(.blue, x: 0, y: 0))
            .composited(over: square(.white, x: 10, y: 0))
    }

    private func centre(_ frame: ClipFraming) -> (r: Double, g: Double, b: Double) {
        let image = FrameRenderer.render(source: quarters, preferredTransform: .identity,
                                         renderSize: CGSize(width: 10, height: 10), frame: frame)
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(image,
                                                                        from: image.extent)!)
        return pixels.rgb(x: 5, y: 5)
    }

    private func clip(_ project: Project) -> VideoSegment? {
        if case .video(let video) = project.segments[0] { video } else { nil }
    }

    @Test func zoomShowsTheCornerTheFramingPicks() {
        let topLeft = centre(ClipFraming(x: 0, y: 0, zoom: 2))
        #expect(topLeft.r > 200 && topLeft.g < 50 && topLeft.b < 50, "\(topLeft)")
        let topRight = centre(ClipFraming(x: 1, y: 0, zoom: 2))
        #expect(topRight.g > 200 && topRight.r < 50, "\(topRight)")
        let bottomLeft = centre(ClipFraming(x: 0, y: 1, zoom: 2))
        #expect(bottomLeft.b > 200 && bottomLeft.r < 50, "\(bottomLeft)")
        let bottomRight = centre(ClipFraming(x: 1, y: 1, zoom: 2))
        #expect(bottomRight.r > 200 && bottomRight.g > 200 && bottomRight.b > 200,
                "\(bottomRight)")
    }

    @Test func eachHalfZoomsOnItsOwn() {
        // 10x20 stacks two 10x10 halves of the square picture.
        let split = SplitScreen(first: ClipFraming(x: 0, y: 0, zoom: 2),
                                second: ClipFraming(x: 1, y: 1, zoom: 2))
        let image = FrameRenderer.render(source: quarters, preferredTransform: .identity,
                                         renderSize: CGSize(width: 10, height: 20), split: split)
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(image,
                                                                        from: image.extent)!)
        let top = pixels.rgb(x: 5, y: 5), bottom = pixels.rgb(x: 5, y: 15)
        #expect(top.r > 200 && top.g < 50, "top: \(top)")
        #expect(bottom.r > 200 && bottom.g > 200 && bottom.b > 200, "bottom: \(bottom)")
    }

    @Test func theVisiblePartShrinksWithZoomAndStaysOnThePicture() {
        let source = CGSize(width: 1920, height: 1080)
        let landscape = CGSize(width: 1920, height: 1080)
        #expect(ClipFraming.centred.visibleRect(sourceSize: source, in: landscape)
            == CGRect(x: 0, y: 0, width: 1, height: 1))
        let zoomed = ClipFraming(x: 1, y: 0, zoom: 2).visibleRect(sourceSize: source,
                                                                   in: landscape)
        #expect(zoomed == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        // Past the limit, zoom stops at 6.
        let most = ClipFraming(x: 0.5, zoom: 9).visibleRect(sourceSize: source, in: landscape)
        #expect(abs(most.width - 1.0 / 6) < 1e-9)
        // Unzoomed, the old crop helper agrees.
        let tall = CGSize(width: 1080, height: 1920)
        #expect(ClipFraming(x: 0.3).visibleRect(sourceSize: source, in: tall)
            == StillFiles.visibleRect(sourceSize: source, renderSize: tall, framing: 0.3))
    }

    @MainActor @Test func reframingSetsAllThreeClampedInOneUndoStep() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(.setSegmentFrame(id: Fixture.id(1),
                                               frame: ClipFraming(x: 1.4, y: -1, zoom: 8))))
        #expect(undo.undoActionName == "Reframe Clip")
        let video = clip(store.project)
        #expect(video?.frame == ClipFraming(x: 1, y: 0, zoom: 6))
        #expect(video?.framing == 1 && video?.framingY == 0 && video?.zoom == 6)
        #expect(!store.perform(.setSegmentFrame(id: Fixture.id(1),
                                                frame: ClipFraming(x: 1, y: 0, zoom: 6))))
        // Back to the defaults stores nothing new.
        store.perform(.setSegmentFrame(id: Fixture.id(1), frame: ClipFraming(x: 1)))
        #expect(clip(store.project)?.framingY == nil && clip(store.project)?.zoom == nil)
        undo.undo()
        undo.undo()
        #expect(store.project == original)
    }

    @Test func olderFilesLoadUnzoomed() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","sourceRange":{"start":0,"duration":600},"framing":0.3,"split":{"first":0.1,"second":0.9}}"#
        let video = try JSONDecoder().decode(VideoSegment.self, from: Data(json.utf8))
        #expect(video.frame == ClipFraming(x: 0.3))
        #expect(video.split == .across(0.1, 0.9))
        var project = Fixture.single
        ProjectCommand.setSegmentFrame(id: Fixture.id(1), frame: ClipFraming(x: 0.2, y: 0.7,
                                                                             zoom: 1.5))
            .apply(to: &project)
        #expect(try ProjectFile.decode(ProjectFile.encode(project)) == project)
        let plain = String(decoding: try ProjectFile.encode(Fixture.single), as: UTF8.self)
        #expect(!plain.contains("zoom") && !plain.contains("framingY"))
    }

    @Test func frameFacesAccountsForZoom() throws {
        let source = CGSize(width: 1920, height: 1080)
        // Same shape: nothing to slide unzoomed; zoomed 2x, half the width shows.
        #expect(FaceFraming.framing(centering: 0.3, sourceSize: source, renderSize: source) == nil)
        let x = try #require(FaceFraming.framing(centering: 0.3, sourceSize: source,
                                                 renderSize: source, zoom: 2))
        let shown = ClipFraming(x: x, zoom: 2).visibleRect(sourceSize: source, in: source)
        #expect(abs(shown.midX - 0.3) < 1e-9)
    }
}
