import Foundation
import Testing
@testable import TitleCutCore

/// The project ID MCP clients address a project by.
@Suite struct ProjectIDTests {
    @Test func newProjectsGetDistinctIDs() {
        #expect(Project.empty.id != Project.empty.id)
    }

    @Test func idIsSavedAndRead() throws {
        let project = Fixture.everything
        let json = try #require(String(data: ProjectFile.encode(project), encoding: .utf8))
        #expect(json.contains(Fixture.projectID.uuidString))
        #expect(try ProjectFile.decode(ProjectFile.encode(project)).id == Fixture.projectID)
    }

    @Test func fileWithoutAnIDReadsWithOne() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: ProjectFile.encode(Fixture.single))
                as? [String: Any])
        object["id"] = nil
        let project = try ProjectFile.decode(JSONSerialization.data(withJSONObject: object))
        #expect(project.id != Fixture.projectID)
        #expect(project.segments == Fixture.single.segments)
    }

    @MainActor
    @Test func renewIDWritesWithoutUndo() {
        let store = ProjectStore(project: Fixture.single)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        var written: [Project] = []
        store.write = { written.append($0) }
        store.renewID()
        #expect(store.project.id != Fixture.projectID)
        #expect(written.map(\.id) == [store.project.id])
        #expect(!undo.canUndo)
        var expected = Fixture.single
        expected.id = store.project.id
        #expect(store.project == expected)
    }
}
