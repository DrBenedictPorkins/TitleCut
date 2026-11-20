import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

/// Add Video: more videos on the one timeline, each clip naming its own
/// (`VideoSegment.sourceID`).
@MainActor
struct MultiVideoTests {
    private let other = SourceVideo(id: Fixture.id(500), bookmark: Data([9]),
                                    lastKnownPath: "/tmp/other.mp4", duration: 1200,
                                    naturalSize: CGSize(width: 360, height: 640), frameRate: 24)

    private func clip(_ project: Project, _ index: Int) -> VideoSegment? {
        if case .video(let video) = project.segments[index] { video } else { nil }
    }

    @Test func addVideoAppendsTheWholeVideoAsOneClip() throws {
        var original = MoveFixture.clips
        original.segments[2].transitionOut = ClipTransition(kind: .dipToBlack, duration: 300)
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        #expect(store.perform(.addVideo(other, segmentID: Fixture.id(20))))
        #expect(undo.undoActionName == "Add Video")
        let project = store.project
        #expect(project.segments.map(\.id).last == Fixture.id(20))
        let added = try #require(clip(project, 3))
        #expect(added.sourceID == other.id)
        #expect(added.sourceRange == TickRange(start: 0, duration: 1200))
        #expect(project.addedSources == [other])
        #expect(TimelineMath.outputDuration(project) == 3000)
        // The end transition stays at the video's end.
        #expect(project.segments[2].transitionOut == nil)
        #expect(project.segments[3].transitionOut?.kind == .dipToBlack)
        // The first video still sets the output.
        #expect(project.output == original.output)

        undo.undo()
        #expect(store.project == original)
    }

    @Test func aVideoAlreadyInTheProjectIsReused() throws {
        var project = MoveFixture.clips
        #expect(ProjectCommand.addVideo(Fixture.source, segmentID: Fixture.id(20))
            .apply(to: &project))
        #expect(clip(project, 3)?.sourceID == nil)
        #expect(project.addedSources.isEmpty)

        var copy = other
        copy.id = Fixture.id(501)
        #expect(ProjectCommand.addVideo(other, segmentID: Fixture.id(21)).apply(to: &project))
        #expect(ProjectCommand.addVideo(copy, segmentID: Fixture.id(22)).apply(to: &project))
        #expect(project.addedSources == [other])
        #expect(clip(project, 5)?.sourceID == other.id)
    }

    @Test func refusedWithoutAFirstVideoOrForATakenID() {
        var empty = Project.empty
        #expect(!ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &empty))
        var project = MoveFixture.clips
        #expect(!ProjectCommand.addVideo(other, segmentID: Fixture.id(1)).apply(to: &project))
        #expect(project == MoveFixture.clips)
    }

    @Test func anAddedVideoGoesWithItsLastClip() {
        var project = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &project)
        // Split in two: deleting one half keeps the video.
        #expect(ProjectCommand.splitSegment(atOutputTime: 2400, newSegmentID: Fixture.id(21))
            .apply(to: &project))
        #expect(clip(project, 4)?.sourceID == other.id)
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(21)).apply(to: &project))
        #expect(project.addedSources == [other])
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(20)).apply(to: &project))
        #expect(project.addedSources.isEmpty)
    }

    /// The timeline colours each clip by its video's place in `sourcesByKey`.
    @Test func eachVideoHasItsOwnPlaceForItsClipColour() {
        var project = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 2400, newSegmentID: Fixture.id(21))
            .apply(to: &project)
        let keys = project.sourcesByKey.map(\.key)
        let places = project.segments.compactMap { segment -> Int? in
            guard case .video(let video) = segment else { return nil }
            return keys.firstIndex(of: video.sourceID)
        }
        #expect(places == [0, 0, 0, 1, 1])
    }

    @Test func trimStaysInsideTheClipsOwnVideo() {
        var project = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &project)
        var longer = project
        // The first video is 3000 long; this one 1200.
        #expect(!ProjectCommand.trimSegment(id: Fixture.id(20),
                                            sourceRange: TickRange(start: 0, duration: 1500),
                                            newGapIDs: MoveFixture.newGaps).apply(to: &longer))
        #expect(ProjectCommand.trimSegment(id: Fixture.id(20),
                                           sourceRange: TickRange(start: 300, duration: 900),
                                           newGapIDs: MoveFixture.newGaps).apply(to: &project))
        // A gap opens where the start was cut.
        #expect(project.segments[3].isGap)
        #expect(clip(project, 4)?.sourceRange == TickRange(start: 300, duration: 900))
    }

    @Test func locatingAnAddedVideoLeavesTheFirstAlone() {
        var project = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &project)
        let moved = SourceVideo(bookmark: Data([7]), lastKnownPath: "/new/other.mp4",
                                duration: 1200, naturalSize: other.naturalSize, frameRate: 24)
        var short = moved
        short.duration = 1199
        #expect(!ProjectCommand.relinkSource(short, sourceID: other.id).apply(to: &project))
        #expect(ProjectCommand.relinkSource(moved, sourceID: other.id).apply(to: &project))
        #expect(project.addedSources.first?.lastKnownPath == "/new/other.mp4")
        #expect(project.addedSources.first?.id == other.id)
        #expect(project.source == Fixture.source)
        #expect(!ProjectCommand.relinkSource(moved, sourceID: Fixture.id(999)).apply(to: &project))
    }

    @Test func olderFilesLoadAndOneVideoSavesWithoutClipVideos() throws {
        let json = #"""
        {"formatVersion":1,"segments":[{"video":{"id":"00000000-0000-0000-0000-000000000001",
        "sourceRange":{"start":0,"duration":600}}}],"titles":[],"styles":[],"stills":[],
        "output":{"size":[640,360],"frameRate":30,"codec":"h264"},
        "source":{"bookmark":"AQID","lastKnownPath":"/tmp/v.mp4","duration":600,
        "naturalSize":[640,360],"frameRate":30}}
        """#
        let project = try ProjectFile.decode(Data(json.utf8))
        #expect(project.addedSources.isEmpty)
        #expect(project.source?.lastKnownPath == "/tmp/v.mp4")
        let saved = String(decoding: try ProjectFile.encode(project), as: UTF8.self)
        #expect(!saved.contains("sourceID"))

        var two = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &two)
        #expect(try ProjectFile.decode(ProjectFile.encode(two)) == two)
    }

    @Test func eachClipFindsItsVideoAndItsWords() {
        var project = MoveFixture.clips
        ProjectCommand.addVideo(other, segmentID: Fixture.id(20)).apply(to: &project)
        let point = TimelineMath.sourcePoint(1800 + 300, in: project)
        #expect(point?.clip.sourceID == other.id && point?.time == 300)
        #expect(project.source(of: point!.clip) == other)
        #expect(project.usedSourceKeys == [nil, other.id])

        // The same source times in both videos: each clip takes its own.
        let words: [UUID?: [TranscriptWord]] = [
            nil: [TranscriptWord(text: "First.", start: 100, end: 200)],
            other.id: [TranscriptWord(text: "Second.", start: 100, end: 200)],
        ]
        let titles = AutoCaptions.titles(for: words, in: project, style: StyleLibrary.caption,
                                         makeID: UUID.init)
        #expect(titles.map(\.text) == ["First.", "Second."])
        #expect(titles.map(\.anchor.segmentID) == [Fixture.id(1), Fixture.id(20)])

        let cuts = SilenceRemoval.cuts(for: [other.id: [TickRange(start: 300, duration: 300)]],
                                       in: project)
        #expect(cuts == [TickRange(start: 2100, duration: 300)])
    }
}

@Suite(.serialized)
struct MultiVideoRenderTests {
    @Test func clipsPlayTheirOwnVideoFilledToTheFrame() async throws {
        let first = try await RenderFixture.numbered.value
        let second = try await RenderFixture.rotated.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: first), segmentID: Fixture.id(1))
            .apply(to: &project)
        // numbered [0, 1 s) | rotated, portrait, whole.
        project.segments = [Fixture.video(1, start: 0, duration: 600)]
        #expect(ProjectCommand.addVideo(try await SourceVideo.load(from: second),
                                        segmentID: Fixture.id(2)).apply(to: &project))
        let key = try #require(project.addedSources.first?.id)

        let sources = try await CompositionBuilder.SourceTracks.load([nil: first, key: second])
        let built = try CompositionBuilder.build(project, sources: sources)
        #expect(Ticks.from(built.composition.duration) == 600 + 3000)

        func frame(at seconds: Double) async throws -> RenderFixture.Pixels {
            let generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return RenderFixture.pixels(of: try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
        }
        // Output 0.5 s: numbered frame 15.
        let early = try await frame(at: 0.5)
        let pixel = early.rgb(x: 320, y: 180)
        let expected = RenderFixture.colour(forFrame: 15)
        #expect(abs(pixel.r - expected.r) < 12 && abs(pixel.g - expected.g) < 12
                && abs(pixel.b - expected.b) < 12, "got \(pixel), expected \(expected)")
        // Output 2 s: the portrait video upright, filling the landscape frame:
        // blue on the left, red on the right, no bars.
        let late = try await frame(at: 2)
        #expect(late.width == 640 && late.height == 360)
        let left = late.rgb(x: 220, y: 180), right = late.rgb(x: 420, y: 180)
        #expect(left.b > 150 && left.r < 80, "left: \(left)")
        #expect(right.r > 150 && right.b < 80, "right: \(right)")

        // Without its file the added clip is black and the timeline keeps its length.
        let missing = try CompositionBuilder.build(project, sources: [nil: sources[nil]!])
        #expect(Ticks.from(missing.composition.duration) == 600 + 3000)
        await #expect(throws: Exporter.ExportError.sourceUnreadable) {
            _ = try await Exporter.loadSources(of: project, from: [nil: first])
        }
    }
}
