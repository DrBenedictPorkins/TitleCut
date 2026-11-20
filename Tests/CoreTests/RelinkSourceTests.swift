import Foundation
import Testing
@testable import TitleCutCore

struct RelinkSourceTests {
    private func source(path: String, duration: Tick) -> SourceVideo {
        SourceVideo(bookmark: Data(path.utf8), lastKnownPath: path, duration: duration,
                    naturalSize: CGSize(width: 1, height: 1), frameRate: 1)
    }

    @Test func locatingKeepsTheEditAndTakesTheNewFile() {
        // v1 [0,600) src 0 | v2 src 600 | v3 src 1200, so 1800 ticks are used.
        var project = MoveFixture.clips
        let found = source(path: "/new/v.mp4", duration: 1800)
        #expect(ProjectCommand.relinkSource(found).apply(to: &project))
        #expect(project.source?.lastKnownPath == "/new/v.mp4")
        #expect(project.source?.bookmark == found.bookmark)
        #expect(project.source?.duration == Fixture.source.duration)
        #expect(project.segments == MoveFixture.clips.segments)
    }

    @Test func refusesAShorterFileNoSourceOrNoChange() {
        var project = MoveFixture.clips
        #expect(!ProjectCommand.relinkSource(source(path: "/short.mp4", duration: 1799))
            .apply(to: &project))
        #expect(!ProjectCommand.relinkSource(Fixture.source).apply(to: &project))
        var empty = Project.empty
        #expect(!ProjectCommand.relinkSource(Fixture.source).apply(to: &empty))
        #expect(project == MoveFixture.clips)
    }

    @Test func aLoadedVideosBookmarkResolvesToIt() async throws {
        let url = try await RenderFixture.numbered.value
        let loaded = try await SourceVideo.load(from: url)
        #expect(loaded.resolveURL()?.standardizedFileURL.resolvingSymlinksInPath()
                == url.standardizedFileURL.resolvingSymlinksInPath())
    }
}
