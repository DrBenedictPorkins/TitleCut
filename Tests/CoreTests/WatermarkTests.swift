import AVFoundation
import Testing
@testable import TitleCutCore

/// The unpaid-export wordmark through `CompositionBuilder` and the compositor.
@Suite(.serialized)
struct WatermarkTests {
    private func gapProject() async throws -> (Project, URL) {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        project.segments = [MoveFixture.gap(5, duration: 1200)]
        return (project, url)
    }

    @Test func everyInstructionCarriesTheMarkOnlyWhenAsked() async throws {
        let (project, url) = try await gapProject()
        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        for watermark in [false, true] {
            let built = try CompositionBuilder.build(project, tracks: tracks, watermark: watermark)
            let instructions = try #require(built.videoComposition?.instructions
                as? [TitleCutInstruction])
            for instruction in instructions {
                #expect(instruction.titles.contains { $0.title.id == Watermark.titleID }
                        == watermark)
            }
        }
        #expect(project.titles.isEmpty)
    }

    @Test func markIsDrawnAcrossTheMiddleOfABlackFrame() async throws {
        let (project, url) = try await gapProject()
        let plain = try await RenderFixture.frame(of: project, from: url, at: 1)
        let marked = try await RenderFixture.frame(of: project, from: url, at: 1, watermark: true)
        func lit(_ pixels: RenderFixture.Pixels) -> Int {
            let y = pixels.height / 2
            return (0..<pixels.width).filter { x in
                let p = pixels.rgb(x: x, y: y)
                return p.r + p.g + p.b > 60
            }.count
        }
        #expect(lit(plain) == 0)
        // Letters cross the centre line over much of the width.
        #expect(lit(marked) > plain.width / 10)
    }

    @Test func portraitMarkStaysInsideTheFrame() {
        let landscape = Watermark.style(renderSize: CGSize(width: 1920, height: 1080))
        let portrait = Watermark.style(renderSize: CGSize(width: 1080, height: 1920))
        #expect(landscape.fontSizeRatio == 0.24)
        #expect(portrait.fontSizeRatio * 1920 * 4.8 < 1080)
    }
}
