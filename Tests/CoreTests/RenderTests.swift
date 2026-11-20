import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// End-to-end: model → CompositionBuilder → TitleCutCompositor → pixels (§11.2).
@Suite(.serialized)
struct RenderTests {
    /// Project over the numbered fixture, as `setSource` would create it.
    private func project(for url: URL) async throws -> Project {
        var project = Project.empty
        let source = try await SourceVideo.load(from: url)
        ProjectCommand.setSource(source, segmentID: Fixture.id(1)).apply(to: &project)
        return project
    }

    private func distance(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g)
            + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// Asserts that output frame `output` shows source frame `source`: its
    /// centre pixel equals a direct decode of that source frame (no
    /// composition), and is clearly nearer to it than to either neighbour.
    private func expectOutputFrame(_ output: Int, showsSource source: Int,
                                   in project: Project, url: URL) async throws {
        let seconds = (Double(output) + 0.5) / Double(RenderFixture.fps)
        let rendered = try await RenderFixture.frame(of: project, from: url, at: seconds)
        let centre = rendered.rgb(x: rendered.width / 2, y: rendered.height / 2)

        let reference = try await RenderFixture.directFrame(source, from: url)
        let expected = reference.rgb(x: reference.width / 2, y: reference.height / 2)
        #expect(distance(centre, expected) <= 2,
                "output \(output): \(centre) vs source \(source) \(expected)")

        for neighbour in [source - 1, source + 1] where (0..<RenderFixture.frameCount)
            .contains(neighbour) {
            let other = try await RenderFixture.directFrame(neighbour, from: url)
            let otherColour = other.rgb(x: other.width / 2, y: other.height / 2)
            #expect(distance(centre, otherColour) > 20,
                    "output \(output) is ambiguous with source \(neighbour)")
        }
    }

    @Test func unsplitProjectShowsSourceFramesInOrder() async throws {
        let url = try await RenderFixture.numbered.value
        let project = try await project(for: url)
        for frame in [0, 1, 29, 30, 75, 149] {
            try await expectOutputFrame(frame, showsSource: frame, in: project, url: url)
        }
    }

    @Test func splitAndDeleteShowsTheRightSourceFrames() async throws {
        let url = try await RenderFixture.numbered.value
        var project = try await project(for: url)
        // Split at 1 s and 3 s, delete the middle: output = src [0,1) + src [3,5).
        ProjectCommand.splitSegment(atOutputTime: 600, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        ProjectCommand.splitSegment(atOutputTime: 1800, newSegmentID: Fixture.id(3))
            .apply(to: &project)
        ProjectCommand.deleteSegment(id: Fixture.id(2)).apply(to: &project)
        #expect(TimelineMath.outputDuration(project) == 1800)

        let expected = [0: 0, 15: 15, 29: 29, 30: 90, 31: 91, 59: 119, 89: 149]
        for (output, source) in expected.sorted(by: { $0.key < $1.key }) {
            try await expectOutputFrame(output, showsSource: source, in: project, url: url)
        }
    }

    @Test func outputIsRenderSizeAndUnscaledFramePassesThrough() async throws {
        let url = try await RenderFixture.numbered.value
        let project = try await project(for: url)
        let pixels = try await RenderFixture.frame(of: project, from: url, at: 0.5 / 30)
        #expect(pixels.width == 640 && pixels.height == 360)
        // Corners carry the frame colour too: no letterbox when sizes match.
        let reference = try await RenderFixture.directFrame(0, from: url)
        #expect(distance(pixels.rgb(x: 2, y: 2), reference.rgb(x: 2, y: 2)) <= 2)
        #expect(distance(pixels.rgb(x: 637, y: 357), reference.rgb(x: 637, y: 357)) <= 2)
    }

    @Test func rotatedSourceIsUprightAndFillsItsPortraitSize() async throws {
        let url = try await RenderFixture.rotated.value
        let project = try await project(for: url)
        // Stored 640x360 with a 90-degree transform: displayed, it is portrait.
        #expect(project.source?.naturalSize == CGSize(width: 360, height: 640))
        let pixels = try await RenderFixture.frame(of: project, from: url, at: 0.5)
        #expect(pixels.width == 360 && pixels.height == 640)
        let mid = pixels.height / 2
        // No bars: the edges carry the picture.
        let edge = pixels.rgb(x: 2, y: mid)
        #expect(edge.r + edge.g + edge.b > 100, "edge: \(edge)")
        // 90 degrees clockwise: stored top (red) is on the right, bottom (blue) on the left.
        let left = pixels.rgb(x: 180 - 50, y: mid)
        let right = pixels.rgb(x: 180 + 50, y: mid)
        #expect(left.b > 150 && left.r < 80, "left half should be blue: \(left)")
        #expect(right.r > 150 && right.b < 80, "right half should be red: \(right)")
    }
}

/// Frame durations snapped from `AVAssetTrack.nominalFrameRate` values.
/// (Rewritten 2026-10-14 after the originals were lost in an edit.)
struct FrameDurationTests {
    @Test func wholeRates() {
        #expect(CompositionBuilder.frameDuration(forRate: 24) == CMTime(value: 1, timescale: 24))
        #expect(CompositionBuilder.frameDuration(forRate: 30) == CMTime(value: 1, timescale: 30))
        #expect(CompositionBuilder.frameDuration(forRate: 60) == CMTime(value: 1, timescale: 60))
    }

    @Test func ntscRatesSnapToRationals() {
        #expect(CompositionBuilder.frameDuration(forRate: 23.976)
                == CMTime(value: 1001, timescale: 24000))
        #expect(CompositionBuilder.frameDuration(forRate: 29.97003)
                == CMTime(value: 1001, timescale: 30000))
        #expect(CompositionBuilder.frameDuration(forRate: 59.94)
                == CMTime(value: 1001, timescale: 60000))
    }

    @Test func float30SnapsToExactThirtieth() {
        let rate = Double(Float(30.0).nextDown)
        #expect(CompositionBuilder.frameDuration(forRate: rate) == CMTime(value: 1, timescale: 30))
    }

    @Test func otherAndInvalidRates() {
        let twelveAndAHalf = CompositionBuilder.frameDuration(forRate: 12.5)
        #expect(abs(twelveAndAHalf.seconds - 0.08) < 1e-6)
        for invalid in [0, -5, Double.nan, Double.infinity] {
            #expect(CompositionBuilder.frameDuration(forRate: invalid)
                    == CMTime(value: 1, timescale: 30))
        }
    }
}

/// `FrameRenderer` geometry on synthetic images.
/// (Rewritten 2026-10-14 after the originals were lost in an edit.)
struct FrameRendererTests {
    private func solid(_ width: CGFloat, _ height: CGFloat) -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func renderFillsWholeCanvas() {
        let frame = FrameRenderer.render(source: solid(16, 9), preferredTransform: .identity,
                                         renderSize: CGSize(width: 9, height: 16))
        #expect(frame.extent == CGRect(x: 0, y: 0, width: 9, height: 16))
    }

    @Test func aspectFitCentresAndLetterboxes() {
        let fitted = FrameRenderer.aspectFit(solid(16, 8), in: CGSize(width: 8, height: 8))
        #expect(fitted.extent == CGRect(x: 0, y: 2, width: 8, height: 4))
    }

    @Test func identityKeepsExtentAtRenderSize() {
        let frame = FrameRenderer.render(source: solid(64, 36), preferredTransform: .identity,
                                         renderSize: CGSize(width: 64, height: 36))
        #expect(frame.extent == CGRect(x: 0, y: 0, width: 64, height: 36))
    }

    @Test func ninetyDegreeTransformMakesPortrait() {
        let turned = FrameRenderer.applyPreferredTransform(
            CGAffineTransform(rotationAngle: .pi / 2), to: solid(64, 36))
        #expect(turned.extent.origin == .zero)
        #expect(abs(turned.extent.width - 36) < 0.001 && abs(turned.extent.height - 64) < 0.001)
    }
}
