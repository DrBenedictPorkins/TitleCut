import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

enum FreezeFixture {
    static let image = StillImage(id: Fixture.id(900), fileName: "frozen.png", capturedAt: 600,
                                  pixelSize: CGSize(width: 640, height: 360))

    static func key(_ time: Tick, x: Double = 0.5, y: Double = 0.5, scale: Double = 1)
        -> ZoomKeyframe {
        ZoomKeyframe(time: time, center: CGPoint(x: x, y: y), scale: scale, easing: .linear)
    }
}

@MainActor
struct FreezeCommandTests {
    typealias F = FreezeFixture

    @Test func freezingSplitsTheClipAndPushesLaterTitles() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(.insertStill(F.image, segmentID: Fixture.id(20),
                                           splitID: Fixture.id(21), atOutputTime: 900,
                                           duration: 1800)))
        let project = store.project
        #expect(project.segments.map(\.id) == [1, 20, 21].map(Fixture.id))
        #expect(project.segments.map(\.duration) == [900, 1800, 2100])
        #expect(project.stills == [F.image])
        // Titles at 0.5 s, 2 s, 4 s: the later two move 3 s later with their half.
        let starts = project.titles.map { TimelineMath.titleOutputRange($0, in: project)?.start }
        #expect(starts == [300, 3000, 4200])
        #expect(undo.undoActionName == "Freeze Frame")
        undo.undo()
        #expect(store.project == original)
    }

    @Test func freezingAtAClipStartDoesNotSplit() {
        var project = Fixture.single
        #expect(ProjectCommand.insertStill(F.image, segmentID: Fixture.id(20),
                                           splitID: Fixture.id(21), atOutputTime: 0,
                                           duration: 600).apply(to: &project))
        #expect(project.segments.map(\.id) == [20, 1].map(Fixture.id))
    }

    @Test func freezingOutsideVideoIsRefused() {
        var project = Fixture.threeSegments
        // 1200..1800 is a still.
        #expect(!ProjectCommand.insertStill(F.image, segmentID: Fixture.id(20),
                                            splitID: Fixture.id(21), atOutputTime: 1500,
                                            duration: 600).apply(to: &project))
    }

    @Test func lengthChangesStretchTheMotion() {
        var project = Fixture.single
        ProjectCommand.insertStill(F.image, segmentID: Fixture.id(20), splitID: Fixture.id(21),
                                   atOutputTime: 900, duration: 1800).apply(to: &project)
        ProjectCommand.setStillZoom(id: Fixture.id(20),
                                    zoom: [F.key(0), F.key(1800, scale: 2)]).apply(to: &project)
        #expect(ProjectCommand.setStillDuration(id: Fixture.id(20), duration: 3600)
            .apply(to: &project))
        guard case .still(let still) = project.segments[1] else {
            Issue.record("not a still"); return
        }
        #expect(still.duration == 3600)
        #expect(still.zoom.map(\.time) == [0, 3600])
    }

    @Test func holdKeepsTheMotionAndGrowsTheFreeze() throws {
        var project = Fixture.single
        ProjectCommand.insertStill(F.image, segmentID: Fixture.id(20), splitID: Fixture.id(21),
                                   atOutputTime: 900, duration: 1800).apply(to: &project)
        // No motion: nothing to hold.
        #expect(!ProjectCommand.setStillHold(id: Fixture.id(20), hold: 600).apply(to: &project))
        ProjectCommand.setStillZoom(id: Fixture.id(20),
                                    zoom: [F.key(0), F.key(1800, x: 0.3, scale: 2)])
            .apply(to: &project)
        let command = ProjectCommand.setStillHold(id: Fixture.id(20), hold: 1200)
        #expect(command.actionName == "Change Freeze Hold")
        #expect(command.apply(to: &project))
        guard case .still(let still) = project.segments[1] else {
            Issue.record("not a still"); return
        }
        #expect(still.duration == 3000)
        #expect(still.zoom.map(\.time) == [0, 1800])
        #expect(still.hold == 1200)
        // The last view holds after the motion ends.
        #expect(StillRenderer.camera(still.zoom, at: 2500).center.x == 0.3)
        #expect(TimelineMath.outputDuration(project) == 900 + 3000 + 2100)

        // Back to none; never negative or above 10 s.
        #expect(ProjectCommand.setStillHold(id: Fixture.id(20), hold: 0).apply(to: &project))
        #expect(project.segments[1].duration == 1800)
        #expect(!ProjectCommand.setStillHold(id: Fixture.id(20), hold: -1).apply(to: &project))
        #expect(!ProjectCommand.setStillHold(
            id: Fixture.id(20), hold: ProjectCommand.maximumStillHold + 1).apply(to: &project))
    }

    @Test func deletingTheLastFreezeDropsItsImage() {
        var project = Fixture.single
        ProjectCommand.insertStill(F.image, segmentID: Fixture.id(20), splitID: Fixture.id(21),
                                   atOutputTime: 900, duration: 1800).apply(to: &project)
        ProjectCommand.deleteSegment(id: Fixture.id(20)).apply(to: &project)
        #expect(project.stills.isEmpty)
    }
}

struct StillCameraTests {
    typealias F = FreezeFixture

    @Test func cameraHoldsBeforeAndAfterAndInterpolatesBetween() {
        let zoom = [F.key(0, x: 0.2, scale: 1), F.key(600, x: 0.8, scale: 3)]
        #expect(StillRenderer.camera(zoom, at: -10).center.x == 0.2)
        #expect(StillRenderer.camera(zoom, at: 900).scale == 3)
        let middle = StillRenderer.camera(zoom, at: 300)
        #expect(abs(middle.center.x - 0.5) < 1e-9 && abs(middle.scale - 2) < 1e-9)
        #expect(StillRenderer.camera([], at: 100).scale == 1)
    }

    @Test func viewFillsTheOutputShapeAndNeverLeavesTheImage() {
        let image = CGSize(width: 1920, height: 1080)
        // 9:16 out of 16:9 at scale 1: full height, 0.316 of the width.
        let tall = StillRenderer.viewRect(center: CGPoint(x: 0.5, y: 0.5), scale: 1,
                                          imageSize: image,
                                          renderSize: CGSize(width: 1080, height: 1920))
        #expect(tall.height == 1 && abs(tall.width - 0.31640625) < 1e-6)
        // Zoomed 2x at the corner: clamped inside.
        let corner = StillRenderer.viewRect(center: .zero, scale: 2, imageSize: image,
                                            renderSize: image)
        #expect(corner == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    @Test func belowOneTheWholePictureFitsWithBars() {
        let image = CGSize(width: 1920, height: 1080)
        let render = CGSize(width: 1080, height: 1920)
        let fit = StillRenderer.fitScale(imageSize: image, renderSize: render)
        #expect(abs(fit - 0.31640625) < 1e-6)
        // At fit: full width, taller than the picture, centred on it.
        let whole = StillRenderer.viewRect(center: CGPoint(x: 0.2, y: 0.9), scale: fit,
                                           imageSize: image, renderSize: render)
        #expect(abs(whole.minX) < 1e-9 && abs(whole.width - 1) < 1e-9)
        #expect(abs(whole.midY - 0.5) < 1e-9 && whole.height > 3)
        // Smaller scales stop at fit.
        #expect(StillRenderer.viewRect(center: CGPoint(x: 0.5, y: 0.5), scale: 0.01,
                                       imageSize: image, renderSize: render) == whole)
        // The same shape needs no bars: fit is 1.
        #expect(StillRenderer.fitScale(imageSize: image, renderSize: image) == 1)
    }

    @Test func zoomedCameraShowsTheChosenQuarter() {
        // Top-left quarter red, the rest blue (Core Image origin is bottom-left).
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 18, width: 32, height: 18))
        let frame = StillRenderer.render(red.composited(over: blue),
                                         zoom: [FreezeFixture.key(0, x: 0.25, y: 0.25, scale: 2)],
                                         at: 0, renderSize: CGSize(width: 64, height: 36))
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(frame, from: frame.extent)!)
        let centre = pixels.rgb(x: 32, y: 18)
        #expect(centre.r > 200 && centre.b < 50, "\(centre)")
    }
}

@Suite(.serialized)
struct FreezeRenderTests {
    @Test func freezeShowsTheGrabbedFrameAndSavesIt() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        // Freeze source frame 15 (0.5 s) at output 0.5 s for 1 s.
        let at: Tick = 300 + 10
        let still = try await StillFiles.grab(from: url, at: at, id: UUID())
        defer { try? FileManager.default.removeItem(at: StillFiles.url(for: still.fileName)) }
        #expect(ProjectCommand.insertStill(still, segmentID: Fixture.id(20),
                                           splitID: Fixture.id(21), atOutputTime: at,
                                           duration: 600).apply(to: &project))
        let reference = try await RenderFixture.directFrame(15, from: url)
        let expected = reference.rgb(x: reference.width / 2, y: reference.height / 2)
        for seconds in [0.6, 1.4] {
            let pixels = try await RenderFixture.frame(of: project, from: url, at: seconds)
            let centre = pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
            let distance = ((centre.r - expected.r) * (centre.r - expected.r)
                + (centre.g - expected.g) * (centre.g - expected.g)
                + (centre.b - expected.b) * (centre.b - expected.b)).squareRoot()
            #expect(distance <= 6, "\(seconds) s: \(centre) vs \(expected)")
        }

        let package = try ProjectFile.package(project, transcripts: [], existing: nil)
        let saved = package.fileWrappers?[ProjectFile.stillsFolderName]?.fileWrappers
        #expect(saved?.keys.sorted() == [still.fileName])
    }
}

struct FreezeCropTests {
    @Test func tallOutputKeepsTheFramedSlice() {
        let source = CGSize(width: 1920, height: 1080)
        let tall = CGSize(width: 1080, height: 1920)
        let left = StillFiles.visibleRect(sourceSize: source, renderSize: tall, framing: 0)
        #expect(left.minX == 0 && left.height == 1 && abs(left.width - 0.31640625) < 1e-6)
        let right = StillFiles.visibleRect(sourceSize: source, renderSize: tall, framing: 1)
        #expect(abs(right.maxX - 1) < 1e-9)
        #expect(StillFiles.visibleRect(sourceSize: source, renderSize: source, framing: 0.2)
                == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func grabbedFreezeIsCroppedToTheVisibleSlice() async throws {
        let url = try await RenderFixture.numbered.value
        let source = try await SourceVideo.load(from: url)
        let crop = StillFiles.visibleRect(sourceSize: source.naturalSize,
                                          renderSize: CGSize(width: 360, height: 640),
                                          framing: 1)
        let still = try await StillFiles.grab(from: url, at: 310, id: UUID(), crop: crop)
        defer { try? FileManager.default.removeItem(at: StillFiles.url(for: still.fileName)) }
        #expect(abs(still.pixelSize.width / still.pixelSize.height - 360.0 / 640.0) < 0.01)
    }
}
