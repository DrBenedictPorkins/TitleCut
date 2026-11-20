import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TitleCutCore

/// Export through `Exporter` and read the file back (§11.2).
@Suite(.serialized)
struct ExportTests {
    /// White box centred on the frame.
    private let style = TitleStyle(
        id: Fixture.id(800), name: "Box", fontName: "Helvetica Neue", fontSizeRatio: 0.1,
        weight: .bold, textColor: RGBA(red: 0, green: 0, blue: 0),
        background: BackgroundBox(color: RGBA(red: 1, green: 1, blue: 1),
                                  paddingRatio: 0.5, cornerRadiusRatio: 0),
        alignment: .center, position: .center, maxWidthRatio: 0.8)

    /// Numbered fixture split at 1.5 s and 3 s with the middle deleted, and one
    /// title over output [1 s, 2 s) that runs across the cut.
    private func project(for url: URL) async throws -> Project {
        var project = Project.empty
        let source = try await SourceVideo.load(from: url)
        ProjectCommand.setSource(source, segmentID: Fixture.id(1)).apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 900, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 1800, newSegmentID: Fixture.id(3))
            .apply(to: &project)
        ProjectCommand.deleteSegment(id: Fixture.id(2)).apply(to: &project)
        project.styles = [style]
        project.titles = [Title(id: Fixture.id(10), text: "Title",
                                anchor: TitleAnchor(segmentID: Fixture.id(1), offset: 600),
                                duration: 600, styleID: style.id)]
        return project
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-export-\(UUID().uuidString).mp4")
    }

    /// A point inside the box's left padding, where the box colour shows.
    private func paddingPoint() throws -> (x: Int, y: Int) {
        let rendered = try #require(TitleRenderer.draw(text: "Title", style: style,
                                                       renderSize: RenderFixture.size))
        let frame = FrameRenderer.titleFrame(contentSize: rendered.contentRect.size,
                                             position: .center, alignment: .center,
                                             renderSize: RenderFixture.size)
        return (Int(frame.minX) + 6, Int(frame.midY))
    }

    private func frame(of url: URL, at frame: Int) async throws -> RenderFixture.Pixels {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: (Double(frame) + 0.5) / Double(RenderFixture.fps),
                          preferredTimescale: 600)
        return RenderFixture.pixels(of: try await generator.image(at: time).image)
    }

    private func distance(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g)
            + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    @Test(arguments: [Codec.h264, .hevc])
    func aSmallerSizeIsScaledAndKeepsItsLength(_ codec: Codec) async throws {
        let source = try await RenderFixture.numbered.value
        var project = try await project(for: source)
        // Large enough that Small scales it down.
        project.output.size = CGSize(width: 1920, height: 1080)
        let output = destination()
        defer { try? FileManager.default.removeItem(at: output) }

        let reported = Mutex<[Double]>([])
        try await Exporter.export(project, sourceURLs: [nil: source], to: output, codec: codec,
                                  size: .small, watermark: false) { fraction in
            reported.withLock { $0.append(fraction) }
        }
        #expect(reported.withLock { $0.last } == 1)
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 960, height: 540))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - Ticks.seconds(TimelineMath.outputDuration(project))) < 0.1)
    }

    @Test(arguments: [Codec.h264, .hevc])
    func exportMatchesTimelineAndShowsTitle(_ codec: Codec) async throws {
        let source = try await RenderFixture.numbered.value
        let project = try await project(for: source)
        let output = destination()
        defer { try? FileManager.default.removeItem(at: output) }

        let reported = Mutex<[Double]>([])
        try await Exporter.export(project, sourceURL: source, to: output, codec: codec, watermark: false) {
            fraction in reported.withLock { $0.append(fraction) }
        }
        #expect(reported.withLock { $0.last } == 1)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let expected = Ticks.seconds(TimelineMath.outputDuration(project))
        #expect(abs(duration.seconds - expected) <= 1 / Double(RenderFixture.fps),
                "exported \(duration.seconds) s, timeline \(expected) s")

        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
        #expect(size == RenderFixture.size)
        let subtype = try #require(formats.first).mediaSubType.rawValue
        #expect(subtype == (codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))

        // Output [1 s, 2 s) is the title; output frame 45 onwards is source 90 onwards.
        let point = try paddingPoint()
        for (frameNumber, sourceFrame, shown) in [(15, 15, false), (35, 35, true),
                                                  (50, 95, true), (75, 120, false)] {
            let pixel = try await frame(of: output, at: frameNumber).rgb(x: point.x, y: point.y)
            if shown {
                #expect(pixel.r > 235 && pixel.g > 235 && pixel.b > 235,
                        "frame \(frameNumber): expected box, got \(pixel)")
            } else {
                let reference = try await RenderFixture.directFrame(sourceFrame, from: source)
                let background = reference.rgb(x: point.x, y: point.y)
                #expect(distance(pixel, background) <= 8,
                        "frame \(frameNumber): expected \(background), got \(pixel)")
            }
        }
    }

    @Test func replacesAnExistingFile() async throws {
        let source = try await RenderFixture.numbered.value
        let project = try await project(for: source)
        let output = destination()
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("old".utf8).write(to: output)

        try await Exporter.export(project, sourceURL: source, to: output, codec: .h264, watermark: false) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration)
        #expect(duration.seconds > 2)
    }

    /// Cancelling the calling task stops the session, throws
    /// `CancellationError` and leaves no file at the destination.
    @Test func cancelLeavesNoFile() async throws {
        let source = try await RenderFixture.numbered.value
        var project = try await project(for: source)
        // 50 s of output so the export is still running when it is cancelled.
        project.segments = (0..<10).map { Fixture.video(100 + $0, start: 0, duration: 3000) }
        project.titles = []
        let output = destination()
        defer { try? FileManager.default.removeItem(at: output) }

        let (started, continuation) = AsyncStream<Double>.makeStream()
        let export = Task {
            try await Exporter.export(project, sourceURL: source, to: output, codec: .h264, watermark: false) {
                continuation.yield($0)
            }
        }
        for await fraction in started where fraction > 0 { break }
        export.cancel()
        let result = await export.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func missingSourceIsReported() async throws {
        let source = try await RenderFixture.numbered.value
        let project = try await project(for: source)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-missing-\(UUID().uuidString).mp4")
        await #expect(throws: Exporter.ExportError.sourceUnreadable) {
            try await Exporter.export(project, sourceURL: missing, to: destination(),
                                      codec: .h264, watermark: false) { _ in }
        }
    }

    @Test func emptyProjectIsReported() async throws {
        let source = try await RenderFixture.numbered.value
        await #expect(throws: Exporter.ExportError.nothingToExport) {
            try await Exporter.export(Project.empty, sourceURL: source, to: destination(),
                                      codec: .h264, watermark: false) { _ in }
        }
    }
}
