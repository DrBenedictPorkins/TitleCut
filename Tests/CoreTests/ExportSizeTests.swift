import CoreGraphics
import Foundation
import Testing
@testable import TitleCutCore

/// `ExportSize`: scaled frames and estimated file sizes.
struct ExportSizeTests {
    private func project(_ size: CGSize, rate: Double, seconds: Int) -> Project {
        var project = MoveFixture.with([Fixture.video(1, start: 0,
                                                      duration: Tick(seconds) * Ticks.perSecond)])
        project.output.size = size
        project.output.frameRate = rate
        return project
    }

    @Test func scaledSizesFitTheLongSideInEvenPixelsAtUpTo30fps() {
        let tall = project(CGSize(width: 886, height: 1920), rate: 59.94, seconds: 10)
        let medium = ExportSize.medium.scaled(tall)
        #expect(medium.output.size == CGSize(width: 590, height: 1280))
        #expect(medium.output.frameRate == 30)
        #expect(ExportSize.large.scaled(tall).output.size == CGSize(width: 886, height: 1920))
        #expect(ExportSize.original.scaled(tall) == tall)
    }

    @Test func estimatesFollowTheDataRateAndLength() throws {
        let tall = project(CGSize(width: 886, height: 1920), rate: 30, seconds: 100)
        // 590 x 1280 x 30 fps x 0.08 bits + 128 kbit/s audio, for 100 s.
        let bytes = try #require(ExportSize.medium.estimatedBytes(of: tall, codec: .h264))
        #expect(bytes == Int(Double(Int(590.0 * 1280 * 30 * 0.08) + 128_000) * 100 / 8))
        let hevc = try #require(ExportSize.medium.estimatedBytes(of: tall, codec: .hevc))
        #expect(hevc < bytes)
        #expect(try #require(ExportSize.small.estimatedBytes(of: tall, codec: .h264)) < bytes)
        #expect(ExportSize.original.estimatedBytes(of: tall, codec: .h264) == nil)
    }
}
