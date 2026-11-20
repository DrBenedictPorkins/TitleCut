import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// Split screen: a clip shown as two halves of the frame, each with its own
/// framing (`VideoSegment.split`).
struct SplitScreenTests {
    /// 16x9: left half red, right half blue.
    private var halves: CIImage {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 9))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 8, y: 0, width: 8, height: 9))
        return blue.composited(over: red)
    }

    private func clip(_ project: Project, _ index: Int) -> VideoSegment? {
        if case .video(let video) = project.segments[index] { video } else { nil }
    }

    @Test func tallAndSquareFramesStackWideOnesSitSideBySide() {
        #expect(SplitScreen.halves(of: CGSize(width: 1080, height: 1920))
            == [CGRect(x: 0, y: 0, width: 1080, height: 960),
                CGRect(x: 0, y: 960, width: 1080, height: 960)])
        #expect(SplitScreen.isStacked(CGSize(width: 1080, height: 1080)))
        #expect(SplitScreen.halves(of: CGSize(width: 1920, height: 1080))
            == [CGRect(x: 0, y: 0, width: 960, height: 1080),
                CGRect(x: 960, y: 0, width: 960, height: 1080)])
        // The odd pixel goes to the second half.
        #expect(SplitScreen.halves(of: CGSize(width: 10, height: 21)).map(\.height) == [10, 11])
    }

    @Test func eachHalfShowsItsOwnPartOfThePicture() {
        // 18x32 (9:16): halves 18x16, narrower than the 16:9 picture.
        let frame = FrameRenderer.render(source: halves, preferredTransform: .identity,
                                         renderSize: CGSize(width: 18, height: 32),
                                         frame: .centred,
                                         split: .across(0, 1))
        #expect(frame.extent == CGRect(x: 0, y: 0, width: 18, height: 32))
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(frame, from: frame.extent)!)
        let top = pixels.rgb(x: 9, y: 8), bottom = pixels.rgb(x: 9, y: 24)
        #expect(top.r > 200 && top.b < 50, "top: \(top)")
        #expect(bottom.b > 200 && bottom.r < 50, "bottom: \(bottom)")
    }

    @MainActor @Test func splittingIsOneUndoStepAndClamps() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(.setSegmentSplit(id: Fixture.id(1),
                                               split: .across(-1, 0.6))))
        #expect(undo.undoActionName == "Split Screen")
        #expect(clip(store.project, 0)?.split == .across(0, 0.6))
        #expect(!store.perform(.setSegmentSplit(id: Fixture.id(1),
                                                split: .across(0, 0.6))))
        #expect(store.perform(.setSegmentSplit(id: Fixture.id(1), split: nil)))
        #expect(clip(store.project, 0)?.split == nil)
        undo.undo()
        undo.undo()
        #expect(store.project == original)
    }

    @Test func onlyVideoClipsSplitAndBothPartsOfACutKeepIt() {
        var project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        MoveFixture.gap(2, duration: 300)])
        #expect(!ProjectCommand.setSegmentSplit(id: Fixture.id(2), split: SplitScreen())
            .apply(to: &project))
        ProjectCommand.setSegmentSplit(id: Fixture.id(1), split: SplitScreen()).apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 300, newSegmentID: Fixture.id(3))
            .apply(to: &project)
        #expect(clip(project, 0)?.split == SplitScreen())
        #expect(clip(project, 1)?.split == SplitScreen())
    }

    @Test func savedWithTheClipAndAbsentFromOlderFiles() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","sourceRange":{"start":0,"duration":600}}"#
        #expect(try JSONDecoder().decode(VideoSegment.self, from: Data(json.utf8)).split == nil)
        let plain = String(decoding: try ProjectFile.encode(Fixture.single), as: UTF8.self)
        #expect(!plain.contains("split"))
        var project = Fixture.single
        ProjectCommand.setSegmentSplit(id: Fixture.id(1), split: .across(0.1, 0.9))
            .apply(to: &project)
        #expect(try ProjectFile.decode(ProjectFile.encode(project)) == project)
    }

    @Test func aFreezeKeepsBothHalves() {
        let source = CGSize(width: 1920, height: 1080)
        let tall = CGSize(width: 1080, height: 1920)
        var video = VideoSegment(id: Fixture.id(1), sourceRange: TickRange(start: 0, duration: 600),
                                 framing: 0.3)
        #expect(StillFiles.visibleRects(sourceSize: source, renderSize: tall, clip: video)
            == [StillFiles.visibleRect(sourceSize: source, renderSize: tall, framing: 0.3)])
        video.split = SplitScreen.across(0, 1)
        let rects = StillFiles.visibleRects(sourceSize: source, renderSize: tall, clip: video)
        // Each half is 1080x960, so it shows 1080/960 of the height's width.
        let width = (1080.0 / 960) / (1920.0 / 1080)
        #expect(rects.count == 2)
        #expect(abs(rects[0].width - width) < 1e-9 && rects[0].minX == 0)
        #expect(abs(rects[1].maxX - 1) < 1e-9 && rects[1].height == 1)
    }
}

extension SplitScreen {
    /// Halves at framings `first` and `second` across the picture, unzoomed.
    static func across(_ first: Double, _ second: Double) -> SplitScreen {
        SplitScreen(first: ClipFraming(x: first), second: ClipFraming(x: second))
    }
}

@Suite(.serialized)
struct SplitScreenRenderTests {
    @Test func theCompositionAndAFreezeDrawBothHalves() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        project.output.size = CGSize(width: 360, height: 640)
        let split = SplitScreen.across(0.2, 0.8)
        ProjectCommand.setSegmentSplit(id: Fixture.id(1), split: split).apply(to: &project)

        let sources = try await CompositionBuilder.SourceTracks.load([nil: url])
        let built = try CompositionBuilder.build(project, sources: sources)
        let contents = try #require(built.videoComposition).instructions.compactMap {
            ($0 as? TitleCutInstruction)?.content
        }
        #expect(contents.contains {
            if case .video(_, _, _, let drawn) = $0 { drawn == split } else { false }
        })

        let clip = try #require(project.segments.first.flatMap {
            if case .video(let video) = $0 { video } else { nil }
        })
        let crops = StillFiles.visibleRects(sourceSize: project.source!.naturalSize,
                                            renderSize: project.output.size, clip: clip)
        let still = try await StillFiles.grab(from: url, at: 0, id: UUID(), crops: crops,
                                              stacked: true)
        defer { try? FileManager.default.removeItem(at: StillFiles.url(for: still.fileName)) }
        // Two 9:8 halves stacked make a 9:16 picture.
        #expect(abs(still.pixelSize.width / still.pixelSize.height - 9.0 / 16) < 0.01,
                "\(still.pixelSize)")
    }
}
