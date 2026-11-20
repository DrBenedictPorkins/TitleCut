import Foundation
import Testing
@testable import TitleCutCore

struct TitleCommandLaneTests {
    /// One 3000-tick segment with titles `(n, offset, duration)` in that order.
    private func project(_ titles: [(Int, Tick, Tick)]) -> Project {
        Project(source: Fixture.source,
                segments: [Fixture.video(1, start: 0, duration: 3000)],
                titles: titles.map { Fixture.title($0.0, segment: 1, offset: $0.1,
                                                   duration: $0.2) })
    }

    private func lanes(_ project: Project) -> [Int?] {
        let lanes = TimelineMath.titleLanes(project)
        return project.titles.map { lanes[$0.id] }
    }

    @Test func noTitlesNoLanes() {
        #expect(TimelineMath.titleLanes(project([])).isEmpty)
    }

    @Test func nonOverlappingTitlesShareLaneZero() {
        #expect(lanes(project([(10, 0, 300), (11, 500, 300), (12, 1000, 300)])) == [0, 0, 0])
    }

    @Test func edgeTouchingTitlesShareALane() {
        #expect(lanes(project([(10, 0, 300), (11, 300, 300), (12, 600, 300)])) == [0, 0, 0])
    }

    @Test func overlappingTitlesStack() {
        // 10 [0,600) · 11 [300,900) · 12 [500,700) · 13 [600,1000)
        #expect(lanes(project([(10, 0, 600), (11, 300, 600), (12, 500, 200), (13, 600, 400)]))
                == [0, 1, 2, 0])
    }

    @Test func overlapByOneTickStacks() {
        #expect(lanes(project([(10, 0, 301), (11, 300, 300)])) == [0, 1])
    }

    @Test func freedLowerLaneIsReused() {
        // 12 overlaps only 11 (lane 1), so it takes lane 0.
        #expect(lanes(project([(10, 0, 300), (11, 100, 1000), (12, 400, 300)])) == [0, 1, 0])
    }

    @Test func titlesOnMissingSegmentAreOmitted() {
        var project = project([(10, 0, 300)])
        project.titles.append(Fixture.title(11, segment: 99, offset: 0))
        #expect(TimelineMath.titleLanes(project) == [Fixture.id(10): 0])
    }

    @Test func titlesAcrossSegmentsUseOutputTime() {
        // threeSegments: title 10 at 100 in seg 1, title 11 at 0 in seg 3 (output 1800).
        var project = Fixture.threeSegments
        project.titles.append(Fixture.title(12, segment: 2, offset: 500, duration: 200))
        // 12 is [1700,1900): overlaps 11 [1800,2100), not 10 [100,400).
        #expect(lanes(project) == [0, 0, 1])
    }

    @Test func deterministic() {
        let project = project([(10, 0, 600), (11, 300, 600), (12, 500, 200)])
        #expect(TimelineMath.titleLanes(project) == TimelineMath.titleLanes(project))
    }

    @Test func movingATitleNeverChangesLanesOfTitlesBeforeIt() {
        var project = project([(10, 0, 600), (11, 300, 600), (12, 700, 600), (13, 1500, 300)])
        let before = TimelineMath.titleLanes(project)
        for start: Tick in stride(from: 0, through: 2700, by: 50) {
            ProjectCommand.moveTitle(id: Fixture.id(13), toOutputStart: start).apply(to: &project)
            let lanes = TimelineMath.titleLanes(project)
            for n in 10...12 {
                #expect(lanes[Fixture.id(n)] == before[Fixture.id(n)])
            }
        }
    }
}
