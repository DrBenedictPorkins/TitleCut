import Foundation
import Testing
@testable import TitleCutCore

struct ProjectCommandTests {
    @Test func setSourceCreatesOneSegment() {
        var project = Project.empty
        #expect(ProjectCommand.setSource(Fixture.source, segmentID: Fixture.id(1))
            .apply(to: &project))
        #expect(project.source == Fixture.source)
        #expect(project.segments == [Fixture.video(1, start: 0, duration: 3000)])
        #expect(project.output.size == Fixture.source.naturalSize)
        #expect(project.output.frameRate == 30)
    }

    @Test func setSourceRefusedWhenSourceExists() {
        var project = Fixture.single
        let before = project
        #expect(!ProjectCommand.setSource(Fixture.source, segmentID: Fixture.id(5))
            .apply(to: &project))
        #expect(project == before)
    }

    @Test func splitReanchorsTitlesToHalfContainingStart() throws {
        var project = Fixture.single  // titles at offsets 300, 1200, 2400
        #expect(ProjectCommand.splitSegment(atOutputTime: 1200, newSegmentID: Fixture.id(2))
            .apply(to: &project))
        #expect(project.segments == [Fixture.video(1, start: 0, duration: 1200),
                                     Fixture.video(2, start: 1200, duration: 1800)])
        let anchors = project.titles.map(\.anchor)
        #expect(anchors == [
            TitleAnchor(segmentID: Fixture.id(1), offset: 300),   // before split: unchanged
            TitleAnchor(segmentID: Fixture.id(2), offset: 0),     // exactly at split: second half
            TitleAnchor(segmentID: Fixture.id(2), offset: 1200),  // after split: shifted
        ])
    }

    @Test func splitPreservesTitleOutputTimes() throws {
        var project = Fixture.single
        let before = project.titles.map { TimelineMath.titleOutputRange($0, in: project) }
        ProjectCommand.splitSegment(atOutputTime: 1000, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        let after = project.titles.map { TimelineMath.titleOutputRange($0, in: project) }
        #expect(before == after)
    }

    @Test func splitOnlyTouchesTitlesOfThatSegment() {
        var project = Fixture.threeSegments
        ProjectCommand.splitSegment(atOutputTime: 2400, newSegmentID: Fixture.id(4))
            .apply(to: &project)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(1), offset: 100))
        #expect(project.titles[1].anchor == TitleAnchor(segmentID: Fixture.id(3), offset: 0))
        #expect(project.segments.map(\.id)
                == [Fixture.id(1), Fixture.id(2), Fixture.id(3), Fixture.id(4)])
    }

    @Test(arguments: [Tick(0), 1200, 1800, 3000, 3001, -5])
    func splitOnBoundaryOrOutsideDoesNothing(time: Tick) {
        var project = Fixture.threeSegments
        let before = project
        #expect(!ProjectCommand.splitSegment(atOutputTime: time, newSegmentID: Fixture.id(4))
            .apply(to: &project))
        #expect(project == before)
    }

    @Test func deleteRemovesSegmentAndItsTitles() {
        var project = Fixture.threeSegments
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(1)).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(2), Fixture.id(3)])
        #expect(project.titles.map(\.id) == [Fixture.id(11)])
    }

    @Test func deleteMissingSegmentDoesNothing() {
        var project = Fixture.threeSegments
        #expect(!ProjectCommand.deleteSegment(id: Fixture.id(99)).apply(to: &project))
        #expect(project == Fixture.threeSegments)
    }

    @Test func actionNames() {
        #expect(ProjectCommand.splitSegment(atOutputTime: 0, newSegmentID: Fixture.id(1))
            .actionName == "Split Segment")
        #expect(ProjectCommand.deleteSegment(id: Fixture.id(1)).actionName == "Delete Segment")
        #expect(ProjectCommand.setSource(Fixture.source, segmentID: Fixture.id(1))
            .actionName == "Open Video")
    }
}

struct ProjectFileTests {
    @Test func roundTripEveryType() throws {
        let project = Fixture.everything
        let decoded = try ProjectFile.decode(ProjectFile.encode(project))
        #expect(decoded == project)
    }

    private func compactJSON(_ segment: Segment) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(segment), encoding: .utf8))
    }

    @Test func videoSegmentExactJSONShape() throws {
        let segment = Fixture.video(1, start: 600, duration: 1200)
        let json = try compactJSON(segment)
        #expect(json == #"{"video":{"id":"00000000-0000-0000-0000-000000000001","#
                + #""sourceRange":{"duration":1200,"start":600}}}"#)
        #expect(try JSONDecoder().decode(Segment.self, from: Data(json.utf8)) == segment)
    }

    @Test func stillSegmentExactJSONShape() throws {
        let segment = Segment.still(StillSegment(
            id: Fixture.id(2), stillID: Fixture.id(900), duration: 1800,
            zoom: [ZoomKeyframe(time: 300, center: CGPoint(x: 0.25, y: 0.5), scale: 2,
                                easing: .easeIn)]))
        let json = try compactJSON(segment)
        #expect(json == #"{"still":{"duration":1800,"id":"00000000-0000-0000-0000-000000000002","#
                + #""stillID":"00000000-0000-0000-0000-000000000900","#
                + #""zoom":[{"center":[0.25,0.5],"easing":"easeIn","scale":2,"time":300}]}}"#)
        #expect(try JSONDecoder().decode(Segment.self, from: Data(json.utf8)) == segment)
    }

    @Test func projectJSONHasNoPositionalKeys() throws {
        let json = try #require(String(data: ProjectFile.encode(Fixture.everything),
                                       encoding: .utf8))
        #expect(!json.contains("\"_0\""))
    }

    @Test(arguments: [#"{}"#, #"{"video":{"id":"00000000-0000-0000-0000-000000000001","sourceRange":{"duration":1,"start":0}},"still":{"duration":1,"id":"00000000-0000-0000-0000-000000000002","stillID":"00000000-0000-0000-0000-000000000900","zoom":[]}}"#])
    func segmentWithoutExactlyOneCaseKeyIsRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Segment.self, from: Data(json.utf8))
        }
    }

    @Test func roundTripEmptyProject() throws {
        let project = Project.empty
        #expect(try ProjectFile.decode(ProjectFile.encode(project)) == project)
    }

    @Test func writesFormatVersion1() throws {
        let json = try #require(String(data: ProjectFile.encode(.empty), encoding: .utf8))
        #expect(json.contains("\"formatVersion\" : 1"))
    }

    @Test func refusesHigherFormatVersion() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: ProjectFile.encode(Fixture.single))
                as? [String: Any])
        object["formatVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ProjectFile.ReadError.newerFormat(found: 2, supported: 1)) {
            try ProjectFile.decode(data)
        }
    }

    @Test func refusalMessageIsPlain() {
        let message = ProjectFile.ReadError.newerFormat(found: 2, supported: 1)
            .localizedDescription
        #expect(message.contains("newer version of TitleCut"))
    }
}
