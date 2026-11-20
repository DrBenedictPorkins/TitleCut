import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

/// Clip speed and volume: `setClipSpeed`, `setClipVolume`, and how speed
/// maps source time to the timeline everywhere.
@MainActor
struct ClipSpeedVolumeTests {
    private func video(_ n: Int, start: Tick, duration: Tick, speed: Double? = nil) -> Segment {
        .video(VideoSegment(id: Fixture.id(n),
                            sourceRange: TickRange(start: start, duration: duration),
                            speed: speed))
    }

    @Test func speedSetsTheLengthOnTheTimeline() {
        let clip = VideoSegment(id: Fixture.id(1), sourceRange: TickRange(start: 600,
                                                                          duration: 1200))
        var fast = clip
        fast.speed = 2
        #expect(Segment.video(fast).duration == 600)
        #expect(fast.sourceOffset(atOutput: 300) == 600)
        #expect(fast.outputOffset(ofSource: 1200) == 300)
        var slow = clip
        slow.speed = 0.75
        #expect(slow.outputDuration == 1600)
    }

    @Test func olderFilesLoadAndNormalClipsSaveWithoutTheFields() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","sourceRange":{"start":0,"duration":600}}"#
        let clip = try JSONDecoder().decode(VideoSegment.self, from: Data(json.utf8))
        #expect(clip.speed == nil && clip.volume == nil && clip.rate == 1)
        let saved = String(decoding: try JSONEncoder().encode(clip), as: UTF8.self)
        #expect(!saved.contains("speed") && !saved.contains("volume"))

        var project = Fixture.single
        #expect(ProjectCommand.setClipSpeed(id: Fixture.id(1), speed: 1.5).apply(to: &project))
        #expect(ProjectCommand.setClipVolume(id: Fixture.id(1), volume: 0.4).apply(to: &project))
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
    }

    @Test func speedMovesLaterClipsAndKeepsTitlesOnTheirFootage() throws {
        // v1 [0,1200) src 0 | v2 src [1200,2400); title 10 on v1 at 600, title 11 on v2.
        var project = MoveFixture.with([video(1, start: 0, duration: 1200),
                                        video(2, start: 1200, duration: 1200)],
                                       titles: [Fixture.title(10, segment: 1, offset: 600),
                                                Fixture.title(11, segment: 2, offset: 0)])
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        #expect(store.perform(.setClipSpeed(id: Fixture.id(1), speed: 2)))
        #expect(undo.undoActionName == "Change Clip Speed")
        #expect(store.project.segments.map(\.duration) == [600, 1200])
        // Title 10 was over source 1 s; at 2x that is output 0.5 s. Its length is kept.
        #expect(store.project.titles[0].anchor.offset == 300)
        #expect(store.project.titles[0].duration == 300)
        #expect(TimelineMath.titleOutputRange(store.project.titles[1], in: store.project)?.start
                == 600)
        #expect(TimelineMath.sourceTime(450, in: store.project) == 900)

        // 1 is normal speed again; refused when unchanged or not offered.
        #expect(!store.perform(.setClipSpeed(id: Fixture.id(1), speed: 2)))
        #expect(!store.perform(.setClipSpeed(id: Fixture.id(1), speed: 12)))
        undo.undo()
        #expect(store.project == project)

        // Not for other kinds of segment.
        project.segments.append(Fixture.still(3, duration: 600))
        #expect(!ProjectCommand.setClipSpeed(id: Fixture.id(3), speed: 2).apply(to: &project))
    }

    @Test func autoCaptionsScaleWithTheirWords() throws {
        var project = MoveFixture.with([video(1, start: 0, duration: 1200)])
        var caption = Fixture.title(10, segment: 1, offset: 400, duration: 400)
        caption.origin = .autoCaption
        caption.words = [TimedWord(text: "a", start: 0, end: 200),
                         TimedWord(text: "b", start: 200, end: 400)]
        project.titles = [caption]
        #expect(ProjectCommand.setClipSpeed(id: Fixture.id(1), speed: 2).apply(to: &project))
        let scaled = project.titles[0]
        #expect(scaled.anchor.offset == 200 && scaled.duration == 200)
        #expect(scaled.words == [TimedWord(text: "a", start: 0, end: 100),
                                 TimedWord(text: "b", start: 100, end: 200)])
    }

    @Test func splitAndTrimWorkInSourceTimeAtSpeed() throws {
        // v1 src [0,2400) at 2x: 1200 long. Title 10 at output 900.
        var project = MoveFixture.with([video(1, start: 0, duration: 2400, speed: 2)],
                                       titles: [Fixture.title(10, segment: 1, offset: 900)])
        var split = project
        #expect(ProjectCommand.splitSegment(atOutputTime: 300, newSegmentID: Fixture.id(2))
            .apply(to: &split))
        guard case .video(let first) = split.segments[0],
              case .video(let second) = split.segments[1] else {
            Issue.record("expected two clips")
            return
        }
        #expect(first.sourceRange == TickRange(start: 0, duration: 600))
        #expect(second.sourceRange == TickRange(start: 600, duration: 1800))
        #expect(second.speed == 2)
        #expect(split.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 600))

        // Trimming 600 source ticks off the start moves the title 300 output ticks.
        #expect(ProjectCommand.trimSegment(id: Fixture.id(1),
                                           sourceRange: TickRange(start: 600, duration: 1800),
                                           newGapIDs: MoveFixture.newGaps).apply(to: &project))
        #expect(project.segments.map(\.duration) == [900])
        #expect(project.titles[0].anchor.offset == 600)
    }

    @Test func silencesAndCaptionsMapToTheTimelineAtSpeed() {
        // v1 src [0,600) | v2 src [1200,2400) at 2x, from output 600.
        let project = MoveFixture.with([video(1, start: 0, duration: 600),
                                        video(2, start: 1200, duration: 1200, speed: 2)])
        let cuts = SilenceRemoval.cuts(for: [TickRange(start: 1800, duration: 300)], in: project)
        #expect(cuts == [TickRange(start: 900, duration: 150)])

        let words = [TranscriptWord(text: "Hi.", start: 1300, end: 1400)]
        let titles = AutoCaptions.titles(for: words, in: project, style: StyleLibrary.caption,
                                         makeID: { Fixture.id(50) })
        #expect(titles.count == 1)
        #expect(titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 50))
        // Held for the minimum caption length, in output time.
        #expect(titles[0].duration == AutoCaptions.Rules().minDuration)
        #expect(titles[0].words?.first.map { $0.end - $0.start } == 50)
    }

    @Test func faceSplitsLandAtTheirOutputTime() {
        let project = MoveFixture.with([video(1, start: 0, duration: 1200, speed: 2)])
        let plan: [UUID: [FaceFraming.Part]] = [
            Fixture.id(1): [.init(sourceStart: 0, framing: 0.2),
                            .init(sourceStart: 600, framing: 0.8)],
        ]
        let commands = FaceFraming.commands(plan, in: project, makeID: { Fixture.id(60) })
        #expect(commands.first == .splitSegment(atOutputTime: 300, newSegmentID: Fixture.id(60)))
    }

    @Test func volumeClampsAndOneIsUnchanged() {
        var project = Fixture.single
        #expect(ProjectCommand.setClipVolume(id: Fixture.id(1), volume: 5).apply(to: &project))
        guard case .video(let loud) = project.segments[0] else { return }
        #expect(loud.volume == VideoSegment.maximumVolume)
        #expect(ProjectCommand.setClipVolume(id: Fixture.id(1), volume: 1).apply(to: &project))
        guard case .video(let normal) = project.segments[0] else { return }
        #expect(normal.volume == nil)
        #expect(!ProjectCommand.setClipVolume(id: Fixture.id(1), volume: nil).apply(to: &project))
        #expect(ProjectCommand.setClipVolume(id: Fixture.id(1), volume: 0).actionName
                == "Change Clip Volume")
    }
}

@Suite(.serialized)
struct ClipSpeedRenderTests {
    @Test func aFastClipPlaysItsSourceInLessTime() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        // src [0,2 s) at 2x | src [3 s,4 s) at normal speed.
        project.segments = [.video(VideoSegment(id: Fixture.id(1),
                                                sourceRange: TickRange(start: 0, duration: 1200),
                                                speed: 2)),
                            Fixture.video(2, start: 1800, duration: 600)]

        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let built = try CompositionBuilder.build(project, tracks: tracks)
        #expect(Ticks.from(built.composition.duration) == 1200)

        // Output 0.5 s is source 1 s (frame 30); output 1.5 s is source 3.5 s (frame 105).
        for (seconds, frame) in [(0.5, 30), (1.5, 105)] {
            let pixels = try await RenderFixture.frame(of: project, from: url, at: seconds)
            let pixel = pixels.rgb(x: pixels.width / 2, y: pixels.height / 2)
            let direct = try await RenderFixture.directFrame(frame, from: url)
            let expected = direct.rgb(x: direct.width / 2, y: direct.height / 2)
            #expect(abs(pixel.r - expected.r) <= 8 && abs(pixel.g - expected.g) <= 8
                    && abs(pixel.b - expected.b) <= 8,
                    "at \(seconds) s: got \(pixel), expected frame \(frame) \(expected)")
        }
    }
}
